import AppKit
import ApplicationServices
import WebKit
import ClipFlowCore
import ImageIO
import PDFKit

@MainActor final class HistoryBrowser: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    var store: HistoryStore?
    var onCommand: ((String, UUID?) -> Void)?
    var slots: [UUID] = []
    var onHotkeyCommand: ((String,String) -> Void)?
    var hotkeyScheme: HotKeyScheme = .command
    var hotkeyEnabled = true
    var hotkeyStatus = ""
    var hotkeyExclusions: [String] = []
    var lastExternalName = "", lastExternalBundleID = ""
    func updateHotkeyControls() {
        let payload: [String:Any] = ["scheme":hotkeyScheme.rawValue,"enabled":hotkeyEnabled,"status":hotkeyStatus,"exclusions":hotkeyExclusions,"externalName":lastExternalName,"externalID":lastExternalBundleID]
        view.callAsyncJavaScript("window.keySettings(payload)",arguments:["payload":payload],in:nil,in:.page,completionHandler:nil)
    }
    private var query = "", kind = ""
    private var offset = 0, generation = 0
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "history")
        view.navigationDelegate = self
        view.uiDelegate = self
        view.loadHTMLString(Self.html, baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateHotkeyControls(); refresh() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = message
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if ["hotkeysToggle","hotkeysCommand","hotkeysOption","hotkeysExclusions","hotkeysExcludeLast","hotkeysRetry"].contains(action) {
            onHotkeyCommand?(action,String((body["value"] as? String ?? "").prefix(50_000))); return
        }
        if action == "list" {
            query = String((body["query"] as? String ?? "").prefix(300)); kind = body["kind"] as? String ?? ""
            offset = max(0, min(1_000_000, body["offset"] as? Int ?? 0)); refresh(); return
        }
        if action == "permissions" || action == "pause" { onCommand?(action,nil); return }
        guard let raw = body["id"] as? String, let id = UUID(uuidString: raw) else { return }
        if action == "preview" { preview(id); return }
        if ["pin","unpin","copy","delete"].contains(action) { onCommand?(action,id) }
    }
    func refresh() {
        guard let store else { return }
        generation += 1
        let current = generation, q = query, filter = kind, page = offset
        Task {
            do {
                let rows = try await store.summaries(query: q, kind: filter, offset: page, limit: 50)
                guard current == generation else { return }
                let data = try JSONEncoder().encode(rows)
                var object = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
                for index in object.indices {
                    if let id = UUID(uuidString: object[index]["id"] as? String ?? ""), let slot = slots.firstIndex(of: id) { object[index]["shortcut"] = hotkeyScheme.symbol + HotKeyService.labels[slot] + (hotkeyEnabled ? "" : "（已释放）") }
                }
                let stats = try await store.stats()
                guard current == generation else { return }
                send(["rows":object,"total":stats.recordCount,"offset":page,"bytes":stats.totalBytes,"authorized":AXIsProcessTrusted() && CGPreflightPostEventAccess()])
            } catch { notify(error.localizedDescription) }
        }
    }
    func notify(_ message: String) {
        view.callAsyncJavaScript("document.getElementById('status').textContent=message", arguments: ["message":message], in: nil, in: .page, completionHandler: nil)
    }
    private func send(_ payload: [String: Any]) {
        view.callAsyncJavaScript("window.render(payload)", arguments: ["payload":payload], in: nil, in: .page, completionHandler: nil)
    }
    private func preview(_ id: UUID) {
        guard let store else { return }
        Task {
            do {
                guard let row = try await store.load(limit: 1, id: id).first else { return }
                var image: NSImage?
                let snap = row.snapshot
                if snap.contentKind == "image" {
                    for item in snap.items {
                        for data in item.representations.values {
                            if let source = CGImageSourceCreateWithData(data as CFData,nil), let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:900] as CFDictionary) { image = NSImage(cgImage:cg,size:.zero); break }
                        }
                        if image != nil { break }
                    }
                } else if let data = snap.items.first?.representations["com.adobe.pdf"], let page = PDFDocument(data:data)?.page(at:0) { image = page.thumbnail(of:NSSize(width:700,height:900),for:.mediaBox) }
                var url = ""
                if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:]) { url = "data:image/png;base64," + png.base64EncodedString() }
                let text = String((snap.plainText ?? snap.summary).prefix(50_000))
                view.callAsyncJavaScript("window.preview(text,url)",arguments:["text":text,"url":url],in:nil,in:.page,completionHandler:nil)
            } catch { notify(error.localizedDescription) }
        }
    }
    static let html = #"""
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'">
<style>
:root{font:14px -apple-system,BlinkMacSystemFont,sans-serif;color:#243047;background:#f3f6fb}*{box-sizing:border-box}body{margin:0}header{background:#fff;padding:25px 30px;border-bottom:1px solid #e2e7ef;display:flex;justify-content:space-between;align-items:center}h1{margin:0;font-size:26px;letter-spacing:-1px}small{color:#708095}button,input,select{font:inherit}button{cursor:pointer;border:1px solid #d4deeb;background:white;border-radius:7px;padding:7px 11px;color:#324568}button:hover{background:#eaf1fe}button.selected{background:#dce7ff;border-color:#6486dd;color:#153fa6}input{flex:1;min-width:100px;padding:11px;border:1px solid #d4deeb;border-radius:9px}select{padding:9px;border:1px solid #d4deeb;border-radius:9px;background:white}.bar{display:flex;gap:10px;padding:20px 30px}.layout{display:grid;grid-template-columns:minmax(350px,1fr) minmax(220px,.65fr);gap:20px;padding:0 30px 25px}.row{background:white;border:1px solid #e1e7f0;border-radius:11px;margin-bottom:10px;padding:15px}.row.pinned{border-left:4px solid #436ff1}.meta{display:flex;gap:8px;align-items:center;color:#7b879d;font-size:12px}.badge{background:#eef2ff;color:#4164c6;padding:3px 7px;border-radius:5px}.content{white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.6;margin:10px 0;max-height:90px;overflow:hidden}.actions{display:flex;gap:6px}aside{background:white;padding:20px;border-radius:12px;align-self:start;position:sticky;top:15px}pre{white-space:pre-wrap;overflow-wrap:anywhere;max-height:400px;overflow:auto;font:13px/1.6 -apple-system,sans-serif}img{max-width:100%;max-height:500px}footer{display:flex;justify-content:space-between;align-items:center;padding:10px 0}#status{padding:8px 30px;color:#5f708b;overflow-wrap:anywhere}.note{font-size:12px;color:#7b879d;line-height:1.7}@media(max-width:720px){.layout{grid-template-columns:1fr}.bar{flex-wrap:wrap}}
</style>
<header><div><h1>ClipFlow <small>剪贴板历史</small></h1><div id="auth" class="note"></div><div class="note">置顶优先占用 12 个快捷键槽位 · 粘贴不会改变顺序 · 仅本机保存</div></div><div><button onclick="send('pause')">暂停 / 恢复</button> <button onclick="send('permissions')">权限设置</button></div></header>
<section style="padding:14px 30px;background:#edf2ff"><strong id="keyStatus">正在检查快捷键…</strong><div style="display:flex;gap:8px;margin:10px 0;flex-wrap:wrap"><button id="toggleKeys" onclick="send('hotkeysToggle')">释放快捷键</button><button id="cmdMode" onclick="send('hotkeysCommand')">Command 模式</button><button id="optMode" onclick="send('hotkeysOption')">Option 回退</button><button onclick="send('hotkeysRetry')">重试注册</button></div><details><summary>按应用排除</summary><p class="note">被排除应用置于前台后，释放全部12键，恢复其原快捷键。应用切换存在通知处理间隔，请等待状态切换；排除不暂停剪贴板收录。</p><textarea id="exclusions" rows="2" style="width:100%;font:inherit" placeholder="应用 Bundle ID，每行一个，例如 com.microsoft.edgemac"></textarea><button onclick="window.webkit.messageHandlers.history.postMessage({action:'hotkeysExclusions',value:$('exclusions').value})">保存排除列表</button> <button id="excludeLast" onclick="send('hotkeysExcludeLast')">排除上次前台应用</button></details><p class="note">接管开启会占用浏览器切标签、缩放等同组合功能；无法保证抢占系统或其他已注册全局快捷键。空槽仍占用组合。暂停监听与释放快捷键相互独立。</p></section>
<div class="bar"><input id="query" placeholder="搜索摘要、文件名或格式标识（文本前4096字节）"><select id="kind"><option value="">全部格式</option><option value="text">纯文本</option><option value="markdown">Markdown</option><option value="rich">富文本 / HTML</option><option value="image">图片</option><option value="file">文件</option><option value="pdf">PDF</option><option value="custom">自定义</option></select><button onclick="page=0;load()">刷新</button></div>
<div id="status">正在读取本地历史…</div><div class="layout"><main><div id="list"></div><footer><button id="prev">上一页</button><span id="count"></span><button id="next">下一页</button></footer></main><aside><h3>内容预览</h3><img id="picture" hidden><pre id="preview">选择一条记录查看内容。图片与 PDF 可查看缩略图。</pre><p class="note">复制按钮保留原始格式，再到目标应用 Command+V。文件仅保存引用，未备份本体。删除仅移除历史索引，数据文件暂保留。</p></aside></div>
<script>
let page=0,timer;const $=id=>document.getElementById(id);function send(action,id){window.webkit.messageHandlers.history.postMessage({action,id})}function load(){window.webkit.messageHandlers.history.postMessage({action:'list',query:$('query').value,kind:$('kind').value,offset:page})}
$('query').oninput=()=>{clearTimeout(timer);timer=setTimeout(()=>{page=0;load()},250)};$('kind').onchange=()=>{page=0;load()};$('prev').onclick=()=>{page=Math.max(0,page-50);load()};$('next').onclick=()=>{page+=50;load()};
const names={markdown:'Markdown',text:'文本',rich:'富文本',image:'图片',file:'文件',pdf:'PDF',custom:'自定义'};
window.keySettings=data=>{$('cmdMode').classList.toggle('selected',data.scheme==='command');$('optMode').classList.toggle('selected',data.scheme==='option');$('keyStatus').textContent=data.status;$('toggleKeys').textContent=data.enabled?'释放全部快捷键':'启用快捷键接管';if(document.activeElement!==$('exclusions'))$('exclusions').value=data.exclusions.join('\n');$('excludeLast').textContent=data.externalID?'排除 '+data.externalName+' ('+data.externalID+')':'尚无外部应用';$('excludeLast').disabled=!data.externalID};
window.render=data=>{const list=$('list');list.replaceChildren();$('auth').textContent=data.authorized?'输入权限已就绪':'跨应用输入需系统授权；历史查看与复制按钮可正常使用';$('status').textContent='';$('count').textContent=`共 ${data.total} 条 · 当前 ${data.offset+1} 起 · ${(data.bytes/1048576).toFixed(1)} MB`;$('prev').disabled=page===0;$('next').disabled=data.rows.length<50;
if(!data.rows.length){const p=document.createElement('p');p.textContent='暂无匹配记录。复制内容后刷新，或调整搜索条件。';list.append(p)}
for(const row of data.rows){const card=document.createElement('section');card.className='row'+(row.pinned?' pinned':'');const meta=document.createElement('div');meta.className='meta';for(const text of [row.shortcut||'历史',names[row.kind]||row.kind,row.pinned?'已置顶':'',new Date(row.copiedAt*1000).toLocaleString()]){if(!text)continue;const s=document.createElement('span');s.textContent=text;meta.append(s)}const content=document.createElement('div');content.className='content';content.textContent=row.preview;const actions=document.createElement('div');actions.className='actions';for(const [label,action] of [['预览','preview'],['复制','copy'],[row.pinned?'取消置顶':'置顶',row.pinned?'unpin':'pin'],['删除','delete']]){const b=document.createElement('button');b.textContent=label;b.onclick=()=>{if(action==='delete'&&!confirm('从历史索引移除此记录？数据文件暂保留。'))return;send(action,row.id)};actions.append(b)}card.append(meta,content,actions);list.append(card)}};
window.preview=(text,url)=>{$('preview').textContent=text;$('picture').hidden=!url;if(url)$('picture').src=url};
</script></html>
"""#
}
