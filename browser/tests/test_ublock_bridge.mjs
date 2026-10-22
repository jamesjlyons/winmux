// Run with node --experimental-vm-modules --test browser/tests/test_ublock_bridge.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = fs.readFileSync(new URL('../ublock/winmux.js', import.meta.url), 'utf8');

async function bridge({ migrated = false, allowed = false, legacy = [] } = {}) {
    const events = [];
    const calls = [];
    const errors = [];
    const storage = { winmuxMigrationV1: migrated };
    const configuration = { filterUpdates: allowed, legacyDisabledSites: legacy, commands: [] };
    const page = { rawURL: 'https://example.test/page', counts: { blocked: { any: 4 } } };
    let enabled = true;
    let tabURL = page.rawURL;
    let listener;
    let interval;
    let context;
    const timeouts = [];
    const ublock = {
        pageStores: new Map([[17, page]]),
        netWhitelist: ['about-scheme'],
        userSettings: { autoUpdate: true },
        scheduleAssetUpdater: details => events.push(['schedule-updates', details]),
        arrayFromWhitelist: value => [...value],
        whitelistFromArray: value => value,
        getNetFilteringSwitch: () => enabled,
        pageStoreFromTabId: id => id === 17 ? {
            toggleNetFilteringSwitch(url, scope, value) {
                events.push(['toggle', url, scope, value]); enabled = value;
            },
        } : undefined,
        updateToolbarIcon: id => events.push(['icon', id]),
    };
    context = vm.createContext({
        URL, console: { error: (...args) => errors.push(args) },
        // The exchange is event-driven; the interval is only a slow fallback.
        setInterval(fn, delay) { assert.equal(delay, 60000); interval = fn; },
        setTimeout(fn, delay) { assert.equal(delay, 1500); timeouts.push(fn); return timeouts.length; },
        chrome: {
            runtime: {},
            winmuxBlocking: {
                exchange(state, callback) {
                    if (calls.length === 0) assert.equal(context.winmuxFilterUpdatesAllowed, false);
                    calls.push(JSON.parse(JSON.stringify(state)));
                    configuration.commands = configuration.commands.filter(c => !state.acknowledged.includes(c.id));
                    callback(structuredClone(configuration));
                },
                onCommand: { addListener(fn) { listener = fn; } },
            },
        },
        vAPI: {
            storage: {
                async get() { return structuredClone(storage); },
                async set(value) { events.push(['save']); Object.assign(storage, structuredClone(value)); },
            },
            tabs: {
                async get(id) { return id === 17 ? { url: tabURL } : undefined; },
                async reload(id) { events.push(['reload', id]); },
            },
        },
    });
    const module = new vm.SourceTextModule(source, { context });
    await module.link(async name => new vm.SyntheticModule(['default'], function() {
        this.setExport('default', name === './background.js' ? ublock : {
            updateStop() { events.push(['stop-updates']); },
        });
    }, { context }));
    await module.evaluate();
    await context.winmuxBlockingReady();
    return { context, configuration, calls, storage, ublock, page, events, errors, timeouts,
        tick: () => interval(), command: () => listener(),
        flushTimeouts: async () => {
            for (const fn of timeouts.splice(0)) { await fn(); }
            await new Promise(resolve => setImmediate(resolve));
        },
        navigate: value => { tabURL = value; } };
}

test('offline startup migrates only valid schemeful exceptions and keeps subdomain boundaries', async () => {
    const b = await bridge({ legacy: ['https://legacy.test', 'http://127.0.0.1',
        'https://[::1]', 'not a URL', 'javascript:alert(1)', null] });
    assert.equal(b.context.winmuxFilterUpdatesAllowed, false);
    assert.equal(b.storage.winmuxMigrationV1, true);
    const rules = b.storage.netWhitelist.slice(1).map(x => new RegExp(x.slice(1, -1)));
    const exempt = url => rules.some(rule => rule.test(url));
    assert(exempt('https://legacy.test/'));
    assert(exempt('https://child.legacy.test:8443/path'));
    assert(exempt('http://127.0.0.1/path'));
    assert(exempt('https://[::1]:8443/path'));
    assert(!exempt('http://legacy.test/'));
    assert(!exempt('https://legacy.test.evil/'));
    assert(!exempt('https://legacyXtest/'));
    assert(!exempt('http://child.127.0.0.1/'));
    assert.equal(b.errors.length, 0);
});

test('a migrated profile preserves its existing whitelist', async () => {
    const b = await bridge({ migrated: true, legacy: ['https://legacy.test'] });
    assert.deepEqual(b.ublock.netWhitelist, ['about-scheme']);
    assert(!b.events.some(x => x[0] === 'save'));
});

test('native site toggle persists before reload and acknowledges the updated state', async () => {
    const b = await bridge({ migrated: true });
    b.configuration.commands = [{ id: 1, tabId: 17, url: b.page.rawURL, enabled: false }];
    await b.command();
    assert(b.events.findIndex(x => x[0] === 'save') < b.events.findIndex(x => x[0] === 'reload'));
    assert.deepEqual(b.calls.at(-1).acknowledged, [1]);
    assert.equal(b.calls.at(-1).pages[0].enabled, false);
    assert.equal(b.configuration.commands.length, 0);
    // A replay after a lost native response must not toggle/reload twice.
    b.configuration.commands = [{ id: 1, tabId: 17, url: b.page.rawURL, enabled: false }];
    await b.tick();
    assert.equal(b.events.filter(x => x[0] === 'reload').length, 1);
    assert.equal(b.errors.length, 0);
});

test('a delayed command cannot toggle a tab after navigation', async () => {
    const b = await bridge({ migrated: true });
    b.configuration.commands = [{ id: 2, tabId: 17, url: b.page.rawURL, enabled: false }];
    b.navigate('https://different.test/');
    await b.command();
    assert(!b.events.some(x => x[0] === 'toggle' || x[0] === 'reload'));
    assert.equal(b.configuration.commands.length, 0);
});

test('each background context owns consent and revocation stops scheduled updates', async () => {
    const a = await bridge({ migrated: true, allowed: true });
    const b = await bridge({ migrated: true, allowed: false });
    assert.equal(a.context.winmuxFilterUpdatesAllowed, true);
    assert.equal(b.context.winmuxFilterUpdatesAllowed, false);
    assert(!a.events.some(x => x[0] === 'stop-updates'));
    a.configuration.filterUpdates = false;
    await a.tick();
    assert.equal(a.context.winmuxFilterUpdatesAllowed, false);
    assert(a.events.some(x => x[0] === 'stop-updates'));
});

test('background snapshot excludes internal pages and caps counters', async () => {
    const b = await bridge({ migrated: true });
    b.page.counts.blocked.any = Number.MAX_SAFE_INTEGER;
    b.ublock.pageStores.set(-1, b.page);
    b.ublock.pageStores.set(18, { rawURL: 'chrome://settings/' });
    await b.tick();
    assert.deepEqual(b.calls.at(-1).pages, [{ tabId: 17, url: b.page.rawURL,
        enabled: true, blocked: 2147483647 }]);
});

test('new consent schedules updates while respecting the uBlock auto-update preference', async () => {
    const b = await bridge({ migrated: true });
    b.configuration.filterUpdates = true;
    await b.tick();
    assert.equal(b.events.filter(x => x[0] === 'schedule-updates').length, 1);
    await b.tick();
    assert.equal(b.events.filter(x => x[0] === 'schedule-updates').length, 1);
    b.configuration.filterUpdates = false;
    await b.tick();
    b.ublock.userSettings.autoUpdate = false;
    b.configuration.filterUpdates = true;
    await b.tick();
    assert.equal(b.events.filter(x => x[0] === 'schedule-updates').length, 1);
});

test('badge updates schedule one trailing exchange and an idle profile exchanges nothing', async () => {
    const b = await bridge({ migrated: true });
    const before = b.calls.length;
    b.ublock.updateToolbarIcon(17);
    b.ublock.updateToolbarIcon(17);
    // uBlock's own updater still runs; the bridge only coalesces its exchange.
    assert.deepEqual(b.events.filter(x => x[0] === 'icon'), [['icon', 17], ['icon', 17]]);
    assert.equal(b.timeouts.length, 1);
    assert.equal(b.calls.length, before);
    await b.flushTimeouts();
    assert.equal(b.calls.length, before + 1);
    assert.equal(b.timeouts.length, 0);
    b.ublock.updateToolbarIcon(17);
    assert.equal(b.timeouts.length, 1);
    assert.equal(b.errors.length, 0);
});
