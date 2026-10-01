#include "chrome/renderer/winmux/cosmetics_agent.h"

#include <set>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
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
}

void CosmeticsAgent::DidDispatchDOMContentLoadedEvent() {
  auto document = render_frame()->GetWebFrame()->GetDocument();
  if (!GURL(document.Url()).SchemeIsHTTPOrHTTPS())
    return;
  render_frame()->GetBrowserInterfaceBroker().GetInterface(
      host_.BindNewPipeAndPassReceiver());
  host_->GetSelectors(InitialTokens(document),
      base::BindOnce(&CosmeticsAgent::Apply, weak_factory_.GetWeakPtr(), document.Token()));
}

void CosmeticsAgent::Apply(blink::DocumentToken token, const std::string& selectors) {
  auto document = render_frame()->GetWebFrame()->GetDocument();
  if (document.Token() != token || selectors.size() > 256 * 1024)
    return;
  auto list = base::JSONReader::ReadList(selectors, base::JSON_PARSE_RFC);
  if (!list)
    return;
  std::string css;
  for (const auto& value : *list) {
    if (value.is_string() && value.GetString().size() <= 4096)
      css += value.GetString() + " { display: none !important; }\n";
    if (css.size() > 256 * 1024)
      return;
  }
  if (!css.empty())
    document.InsertStyleSheet(blink::WebString::FromUtf8(css), nullptr,
                              blink::WebCssOrigin::kUser);
}

void CosmeticsAgent::OnDestruct() {
  delete this;
}
}  // namespace winmux
