#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

$stdout.sync = true
ISSUES = [
  { id: "issue-1", titleKey: "issue.first", subtitleKey: "issue.first.detail", systemImage: "circle" },
  { id: "issue-2", titleKey: "issue.second", subtitleKey: "issue.second.detail", systemImage: "circle.lefthalf.filled" }
]

def sidebar_document
  {
    schemaVersion: 1,
    components: [{ id: "issues", kind: "section", titleKey: "destination.issues", children: ISSUES.map { |issue| issue.merge(kind: "row") } }]
  }
end

def app_html
  <<~HTML
    <!doctype html><html><body><main><h1 id="title"></h1><p id="selection"></p><button id="create"></button><button id="edit"></button><button id="close"></button></main><script>
    const m={en:{title:"Issue Panel",selected:"Selected",create:"Create issue",edit:"Edit issue",close:"Close issue"},"zh-Hans":{title:"Issue 面板",selected:"当前选择",create:"创建 Issue",edit:"编辑 Issue",close:"关闭 Issue"}};
    let nextID=1,context={};const pending=new Map();
    function request(method,params){const id=nextID++;parent.postMessage({jsonrpc:"2.0",id,method,params},"*");return new Promise((resolve,reject)=>pending.set(id,{resolve,reject}))}
    function notify(method,params){parent.postMessage({jsonrpc:"2.0",method,params},"*")}
    // 页面是 WKWebView 的顶层文档，parent === window：自己 postMessage 出去的请求
    // 会原样回到这个监听器。带 method 的一律是请求/通知，绝不能当成响应处理，
    // 否则 ui/initialize 会被自己的回声「解决」成 undefined。
    addEventListener("message",event=>{const message=event.data;if(!message||message.jsonrpc!=="2.0")return;if(typeof message.method==="string"){if(message.method==="ui/notifications/host-context-changed"){context={...context,...(message.params?.willdeep||{})};draw(context)}return}if(message.id===undefined||message.id===null||!pending.has(message.id))return;const waiter=pending.get(message.id);pending.delete(message.id);message.error?waiter.reject(new Error(message.error.message)):waiter.resolve(message.result)});
    const titleLabel=document.getElementById("title"),selectionLabel=document.getElementById("selection"),createButton=document.getElementById("create"),editButton=document.getElementById("edit"),closeButton=document.getElementById("close");
    function draw(c){const t=m[(c.locale||"").startsWith("zh")?"zh-Hans":"en"];titleLabel.textContent=t.title;selectionLabel.textContent=t.selected+": "+(c.selectedItemID||"—");createButton.textContent=t.create;editButton.textContent=t.edit;closeButton.textContent=t.close;editButton.disabled=closeButton.disabled=!c.selectedItemID}
    function callTool(name,args){return request("tools/call",{name,arguments:args})}
    createButton.onclick=()=>callTool("issues.create",{});
    editButton.onclick=()=>callTool("issues.edit",{id:context.selectedItemID});
    closeButton.onclick=()=>callTool("issues.close",{id:context.selectedItemID});
    request("ui/initialize",{protocolVersion:"2026-01-26",appCapabilities:{},clientInfo:{name:"willdeep-issue-panel",version:"1.0.0"}}).then(result=>{context=(result&&result.hostContext&&result.hostContext.willdeep)||{};notify("ui/notifications/initialized",{});draw(context)});
    </script></body></html>
  HTML
end

ARGF.each_line do |line|
  request = JSON.parse(line)
  next unless request["id"]
  result = case request["method"]
           when "initialize"
             { protocolVersion: "2025-06-18", capabilities: { resources: { subscribe: true }, tools: {} }, serverInfo: { name: "issue-manager", version: "1.0.0" } }
           when "resources/read"
             uri = request.dig("params", "uri")
             text = uri == "ui://issues/main" ? app_html : JSON.generate(sidebar_document)
             mime_type = uri == "ui://issues/main" ? "text/html;profile=mcp-app" : "application/json"
             { contents: [{ uri: uri, mimeType: mime_type, text: text }] }
           when "resources/subscribe"
             {}
           when "tools/list"
             issue_input = { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
             { tools: [
               { name: "issues.create", description: "Create an issue", inputSchema: { type: "object", properties: {} } },
               { name: "issues.edit", description: "Edit an issue", inputSchema: issue_input },
               { name: "issues.close", description: "Close an issue", inputSchema: issue_input }
             ] }
           when "tools/call"
             tool_name = request.dig("params", "name")
             issue_id = request.dig("params", "arguments", "id")
             case tool_name
             when "issues.create"
               issue_id = "issue-created"
               ISSUES << { id: issue_id, titleKey: "issue.created", subtitleKey: "issue.created.detail", systemImage: "circle" } unless ISSUES.any? { |issue| issue[:id] == issue_id }
             when "issues.edit"
               issue = ISSUES.find { |item| item[:id] == issue_id }
               issue[:subtitleKey] = "issue.edited.detail" if issue
             when "issues.close"
               ISSUES.reject! { |issue| issue[:id] == issue_id }
             end
             { content: [{ type: "text", text: JSON.generate(ok: true, tool: tool_name, id: issue_id) }] }
           else
             {}
           end
  puts JSON.generate(jsonrpc: "2.0", id: request["id"], result: result)
  if request["method"] == "tools/call"
    puts JSON.generate(
      jsonrpc: "2.0",
      method: "notifications/resources/updated",
      params: { uri: "willdeep-plugin://issues/sidebar" }
    )
  end
rescue JSON::ParserError => error
  warn error.message
end
