#include "chrome/renderer/winmux/cosmetics_agent.h"

#include <set>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "gin/converter.h"
#include "gin/function_template.h"
#include "third_party/blink/public/web/web_script_source.h"
#include "v8/include/v8.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_split.h"
#include "content/public/renderer/render_frame.h"
#include "third_party/blink/public/platform/browser_interface_broker_proxy.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_element.h"
#include "third_party/blink/public/web/web_local_frame.h"

namespace winmux {
namespace {
std::string InitialTokens(const blink::WebDocument& document) {
  std::set<std::string> classes;
  std::set<std::string> ids;
  std::vector<blink::WebNode> pending;
  if (!document.DocumentElement().IsNull())
    pending.push_back(document.DocumentElement());
  size_t visited = 0;
  while (!pending.empty() && visited++ < 2048 && classes.size() + ids.size() < 512) {
    blink::WebNode node = pending.back();
    pending.pop_back();
    if (node.IsElementNode()) {
      blink::WebElement element = node.To<blink::WebElement>();
      auto class_value = element.GetAttribute(blink::WebString::FromUtf8("class"));
      if (class_value.length() <= 4096) {
        for (auto& token : base::SplitString(class_value.Utf8(), " \t\n\r\f",
                                             base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
          if (classes.size() + ids.size() >= 512)
            break;
          if (token.size() <= 128)
            classes.insert(std::move(token));
        }
      }
      auto id = element.GetAttribute(blink::WebString::FromUtf8("id"));
      if (!id.IsEmpty() && id.length() <= 128 && classes.size() + ids.size() < 512)
        ids.insert(id.Utf8());
    }
    for (auto child = node.FirstChild(); !child.IsNull() && pending.size() + visited < 2048;
         child = child.NextSibling())
      pending.push_back(child);
  }
  base::ListValue class_list;
  base::ListValue id_list;
  for (const auto& value : classes)
    class_list.Append(value);
  for (const auto& value : ids)
    id_list.Append(value);
  base::DictValue tokens;
  tokens.Set("classes", std::move(class_list));
  tokens.Set("ids", std::move(id_list));
  auto json = base::WriteJson(tokens).value_or("{}");
  return json.size() <= 64 * 1024 ? json : "{\"classes\":[],\"ids\":[]}";
}
}  // namespace

CosmeticsAgent::CosmeticsAgent(content::RenderFrame* frame)
    : RenderFrameObserver(frame) {}

CosmeticsAgent::~CosmeticsAgent() = default;

void CosmeticsAgent::DidCreateNewDocument() {
  weak_factory_.InvalidateWeakPtrs();
  host_.reset();
  applied_.clear(); css_bytes_ = 0; tokens_.clear(); query_pending_ = false;
}

void CosmeticsAgent::DidDispatchDOMContentLoadedEvent() {
  // Blink calls this observer inside ScriptForbiddenScope. Defer execution
  // until that scope has ended; navigation invalidates the pending task.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&CosmeticsAgent::InstallObserver,
                               weak_factory_.GetWeakPtr()));
}

void CosmeticsAgent::InstallObserver() {
  auto document = render_frame()->GetWebFrame()->GetDocument();
  if (!GURL(document.Url()).SchemeIsHTTPOrHTTPS())
    return;
  render_frame()->GetBrowserInterfaceBroker().GetInterface(
      host_.BindNewPipeAndPassReceiver());
  Tokens(InitialTokens(document));
  // This local script only sends bounded DOM token deltas. It is isolated from
  // page JavaScript, receives no workspace API, and never scans on a timer.
  render_frame()->GetWebFrame()->ExecuteScriptInIsolatedWorld(ISOLATED_WORLD_ID_WINMUX_COSMETICS,
      blink::WebScriptSource(blink::WebString::FromUtf8(R"JS(
(() => {
  const seen = new Set(), pending = new Set(); let timer = 0;
  function flush() {
    timer = 0;
    const classes = [], ids = [], nodes = [...pending]; pending.clear();
    let visited = 0;
    while (nodes.length && visited++ < 2048 && classes.length + ids.length < 512) {
      const el = nodes.pop(); if (el.nodeType !== 1) continue;
      const add = (kind, token, list) => {
        if (!token || token.length > 128 || classes.length + ids.length >= 512 || seen.size >= 4096 || seen.has(kind + token)) return;
        seen.add(kind + token); list.push(token);
      };
      if ((el.getAttribute('class') || '').length <= 4096)
        for (const value of el.classList) add('.', value, classes);
      add('#', el.id, ids);
      for (const child of el.children) { if (nodes.length + visited >= 2048) break; nodes.push(child); }
    }
    if (classes.length || ids.length) globalThis.__winmuxTokens(JSON.stringify({classes, ids}));
    if (seen.size >= 4096) observer.disconnect();
  }
  const observer = new MutationObserver(records => {
    for (const record of records) {
      if (pending.size >= 2048) break;
      if (record.type === 'attributes') pending.add(record.target);
      else for (const node of record.addedNodes) { if (pending.size >= 2048) break; pending.add(node); }
    }
    if (!timer && pending.size) timer = setTimeout(flush, 100);
  });
  observer.observe(document.documentElement, {subtree:true, childList:true, attributes:true, attributeFilter:['class','id']});
})();
)JS")), blink::BackForwardCacheAware::kAllow);
}

void CosmeticsAgent::DidCreateScriptContext(v8::Local<v8::Context> context, int32_t world_id) {
  if (world_id != ISOLATED_WORLD_ID_WINMUX_COSMETICS) return;
  auto* isolate = v8::Isolate::GetCurrent();
  v8::HandleScope scope(isolate);
  context->Global()->Set(context, gin::StringToV8(isolate, "__winmuxTokens"),
      gin::CreateFunctionTemplate(isolate, base::BindRepeating(&CosmeticsAgent::Tokens, weak_factory_.GetWeakPtr()))
          ->GetFunction(context).ToLocalChecked()).Check();
}
void CosmeticsAgent::Tokens(const std::string& tokens) {
  if (!host_.is_bound() || tokens.size() > 64 * 1024 || css_bytes_ >= 512 * 1024 || tokens_.size() >= 16) return;
  tokens_.push_back(tokens);
  QueryNext();
}
void CosmeticsAgent::QueryNext() {
  if (query_pending_ || tokens_.empty() || !host_.is_bound()) return;
  query_pending_ = true;
  auto tokens = std::move(tokens_.front()); tokens_.pop_front();
  const auto document = render_frame()->GetWebFrame()->GetDocument();
  host_->GetSelectors(tokens, base::BindOnce(&CosmeticsAgent::Apply, weak_factory_.GetWeakPtr(), document.Token()));
}

void CosmeticsAgent::Apply(blink::DocumentToken token, const std::string& selectors) {
  query_pending_ = false;
  QueryNext();
  auto document = render_frame()->GetWebFrame()->GetDocument();
  if (document.Token() != token || selectors.size() > 256 * 1024)
    return;
  auto list = base::JSONReader::ReadList(selectors, base::JSON_PARSE_RFC);
  if (!list)
    return;
  std::string css;
  for (const auto& value : *list) {
    if (value.is_string() && value.GetString().size() <= 4096 &&
        value.GetString().find_first_of("{}") == std::string::npos && applied_.insert(value.GetString()).second)
      css += value.GetString() + " { display: none !important; }\n";
    if (css.size() > 256 * 1024)
      return;
  }
  css_bytes_ += css.size();
  if (!css.empty() && css_bytes_ <= 512 * 1024)
    document.InsertStyleSheet(blink::WebString::FromUtf8(css), nullptr,
                              blink::WebCssOrigin::kUser);
}

void CosmeticsAgent::OnDestruct() {
  delete this;
}
}  // namespace winmux
