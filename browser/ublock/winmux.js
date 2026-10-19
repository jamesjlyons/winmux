// WinMux integration for uBlock Origin. Licensed under GPL-3.0.
import µb from './background.js';
import io from './assets.js';

const api = chrome.winmuxBlocking;
if (!api) { throw new Error('WinMux blocking API is unavailable'); }
const exchange = state => new Promise((resolve, reject) => {
    api.exchange(state, response => {
        const error = chrome.runtime.lastError;
        if (error) { reject(new Error(error.message)); } else { resolve(response); }
    });
});

// Default closed before any upstream startup code can fetch remote assets.
globalThis.winmuxFilterUpdatesAllowed = false;
let configuration = await exchange({ pages: [], acknowledged: [] });
globalThis.winmuxFilterUpdatesAllowed = configuration.filterUpdates === true;
let running = false;
let ready = false;
let acknowledged = [];
const completed = new Set();

function pageStates() {
    const pages = [];
    for (const [tabId, page] of µb.pageStores) {
        if (tabId < 0 || !/^https?:\/\//.test(page.rawURL)) { continue; }
        pages.push({ tabId, url: page.rawURL,
            enabled: µb.getNetFilteringSwitch(page.rawURL),
            blocked: Math.min(2147483647, page.counts.blocked.any) });
        if (pages.length === 1024) { break; }
    }
    return pages;
}

async function pump() {
    if (!ready || running) { return; }
    running = true;
    try {
        configuration = await exchange({ pages: pageStates(), acknowledged });
        acknowledged = [];
        const wasAllowed = globalThis.winmuxFilterUpdatesAllowed;
        globalThis.winmuxFilterUpdatesAllowed = configuration.filterUpdates === true;
        if (!globalThis.winmuxFilterUpdatesAllowed) { io.updateStop(); }
        if (!wasAllowed && globalThis.winmuxFilterUpdatesAllowed && µb.userSettings.autoUpdate) {
            µb.scheduleAssetUpdater({ auto: true, updateDelay: 2000 });
        }
        for (const command of configuration.commands) {
            if (completed.has(command.id)) { acknowledged.push(command.id); continue; }
            const tab = await vAPI.tabs.get(command.tabId);
            // A delayed command must never change the site after navigation.
            if (tab && tab.url === command.url) {
                const page = µb.pageStoreFromTabId(command.tabId);
                if (!page) { continue; }
                page.toggleNetFilteringSwitch(command.url, '', command.enabled);
                await vAPI.storage.set({ netWhitelist: µb.arrayFromWhitelist(µb.netWhitelist) });
                µb.updateToolbarIcon(command.tabId, 0b111);
                await vAPI.tabs.reload(command.tabId);
            }
            completed.add(command.id);
            acknowledged.push(command.id);
        }
        if (acknowledged.length) {
            configuration = await exchange({ pages: pageStates(), acknowledged });
            acknowledged = [];
        }
        // Commands are bounded in the browser; keep deduplication bounded too.
        if (completed.size > 1024) {
            const oldest = [...completed].slice(0, completed.size - 512);
            for (const id of oldest) { completed.delete(id); }
        }
    } catch (error) {
        console.error('WinMux blocking synchronization:', error);
    } finally { running = false; }
}

globalThis.winmuxBlockingReady = async () => {
    const stored = await vAPI.storage.get('winmuxMigrationV1');
    if (stored.winmuxMigrationV1 !== true) {
        const directives = µb.arrayFromWhitelist(µb.netWhitelist);
        for (const site of configuration.legacyDisabledSites) {
            let url;
            try { url = new URL(site); } catch { continue; }
            if (!/^https?:$/.test(url.protocol)) { continue; }
            const escaped = url.hostname.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            const ip = url.hostname.startsWith('[') || /^\d+\.\d+\.\d+\.\d+$/.test(url.hostname);
            const subdomains = ip ? '' : '(?:[^/]+\\.)?';
            // Retain the old schemeful-site boundary, including subdomains.
            directives.push(`/^${url.protocol}\\/\\/${subdomains}${escaped}(?::[0-9]+)?\\//`);
        }
        µb.netWhitelist = µb.whitelistFromArray(directives);
        µb.netWhitelistModifyTime = Date.now();
        await vAPI.storage.set({ netWhitelist: µb.arrayFromWhitelist(µb.netWhitelist), winmuxMigrationV1: true });
    }
    ready = true;
    api.onCommand.addListener(pump);
    await pump();
    setInterval(pump, 1000);
};
