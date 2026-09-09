// Browser-level UI check with a deterministic host bridge; no paid model calls.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs');
const assert = require('node:assert/strict');

(async () => {
  const out = process.env.VIDEO_STUDIO_EVIDENCE || '/tmp/video-studio-evidence';
  fs.mkdirSync(out, { recursive: true });
  fs.rmSync(out + '/report.json', { force: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  const failures = [];
  page.on('pageerror', (error) => failures.push(error.message));
  await page.addInitScript(() => {
    const drama = { id: 'd', title: '三日短信', genre: '悬疑', format: '竖屏', logline: '程序员收到未来的预警', tone: '克制', episodeCount: 1, episodeDurationSeconds: 90, status: 'planning', characters: [{ id: 'c', name: '陈默', description: '程序员，收到未来短信。'.repeat(80), visualPrompt: '短发、灰色外套', candidates: [], rev: 0, draftRev: 0 }], episodes: [{ id: 'e', order: 1, title: '未来来信', summary: '手机亮起', script: '陈默：这怎么可能。旧手机显示三天后的日期。', shots: [], rev: 0, draftRev: 0 }] };
    const messages = [];
    const result = (value) => JSON.stringify({ ok: true, ...value });
    window.willdeep = {
      getContext: () => ({ locale: 'zh-Hans' }),
      skills: { list: async () => ({ skills: [] }) },
      executeCommand: async (command, args = {}) => {
        const episode = drama.episodes[0];
        if (command === 'drama.list') return result({ dramas: [drama] });
        if (command === 'chat.list') return result({ messages: messages.filter((entry) => entry.stage === args.stage) });
        if (command === 'chat.append') { const message = { id: String(messages.length), ...args.message, stage: args.stage }; messages.push(message); return result({ message }); }
        if (command === 'drama.listShots') return result({ shots: episode.shots });
        if (command === 'drama.saveShotDrafts') {
          episode.shots = args.shots.map((draft) => ({ id: 's' + draft.order, order: draft.order, title: '', summary: '', dialogue: [], duration: 4, actionStart: '', actionEnd: '', cameraIntent: '', startPrompt: '', endPrompt: '', startCandidates: [], endCandidates: [], rev: 0, draftRev: 1, draftOnly: true, draft }));
          return result({ drama, applied: args.shots.map((entry) => entry.order) });
        }
        const shot = episode.shots.find((entry) => entry.id === args.shotID);
        if (command === 'drama.saveDraft') { shot.draft = { ...shot.draft, ...args.draft }; shot.draftRev++; return result({ drama }); }
        if (command === 'drama.commitDraft') { Object.assign(shot, shot.draft); shot.draft = null; shot.draftOnly = false; shot.rev++; shot.draftRev++; return result({ drama }); }
        return result({});
      },
      ai: {
        providers: async () => ({ providers: [{ providerID: 'fixture', displayName: 'Test provider', isActive: true, models: ['gpt-5.6-sol'], flashModel: 'gpt-5.6-sol' }] }),
        complete: async ({ system, messages }) => ({ text: system.includes('short_drama_frames') && messages.at(-1).content.includes('只改尾帧') ? '```short_drama_frames\n{"endPrompt":"窗外闪过一道车灯"}\n```' : system.includes('short_drama_frames') ? '```short_drama_frames\n{"startPrompt":"手机冷光照亮陈默的脸","endPrompt":"陈默抬头望向窗外"}\n```' : '```short_drama_shots\n{"shots":[{"order":1,"title":"来信","summary":"手机亮起，陈默发现日期异常","dialogue":[{"speaker":"陈默","text":"这怎么可能"}],"actionStart":"低头看手机","actionEnd":"抬头看窗外","cameraIntent":"面部近景","duration":4}]}\n```', model: 'gpt-5.6-sol', providerID: 'fixture' }),
      },
    };
  });
  try {
    await page.goto(process.env.VIDEO_STUDIO_URL || 'http://127.0.0.1:5178');
    await page.getByRole('button', { name: '继续创作', exact: true }).first().click();
    await page.locator('.character-pick').first().click();
    await page.screenshot({ path: out + '/characters-wide.png' });
    assert(await page.locator('.character-list').evaluate((node) => node.getBoundingClientRect().height <= 230));
    await page.getByRole('button', { name: /04 分镜/ }).click();
    await page.getByRole('button', { name: 'AI 从剧本生成分镜', exact: true }).click();
    await page.getByRole('button', { name: '采用分镜草稿' }).click();
    await page.getByRole('button', { name: '采用分镜草稿' }).waitFor({ state: 'hidden' });
    await page.screenshot({ path: out + '/storyboard-wide.png' });
    assert.equal(await page.locator('.shot-content > label textarea').inputValue(), '手机亮起，陈默发现日期异常');
    await page.getByRole('button', { name: /05 首尾帧/ }).click();
    await page.getByRole('button', { name: 'AI 共创描述' }).click();
    await page.getByRole('button', { name: '采用分镜草稿' }).click();
    await page.getByRole('button', { name: '采用分镜草稿' }).waitFor({ state: 'hidden' });
    assert.equal(await page.locator('.prompt-box').first().inputValue(), '手机冷光照亮陈默的脸');

    await page.getByLabel('想怎样修改画面', { exact: true }).fill('只改尾帧，窗外闪过一道车灯');
    await page.getByRole('button', { name: 'AI 共创描述' }).click();
    await page.getByRole('button', { name: '采用分镜草稿' }).click();
    await page.getByRole('button', { name: '采用分镜草稿' }).waitFor({ state: 'hidden' });
    assert.equal(await page.locator('.prompt-box').first().inputValue(), '手机冷光照亮陈默的脸');
    assert.equal(await page.locator('.prompt-box').nth(1).inputValue(), '窗外闪过一道车灯');
    await page.screenshot({ path: out + '/frames-wide.png' });

    await page.setViewportSize({ width: 900, height: 900 });
    await page.screenshot({ path: out + '/frames-narrow.png' });
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1));
    const modelWidth = await page.locator('.frame-chat [aria-label="聊天模型"]').evaluate((node) => node.getBoundingClientRect().width);
    assert(modelWidth >= 180, 'model picker too narrow');
    assert.equal(failures.length, 0, failures.join('\n'));
    fs.writeFileSync(out + '/report.json', JSON.stringify({ passed: true, scope: 'Deterministic browser bridge, no paid model requests', checks: ['character-list-bounded', 'empty-to-generated-storyboard', 'adopt-visible-shot-draft', 'frame-chat-to-adopted-description', 'repeated-frame-revision-preserves-other-field', 'narrow-layout-no-overflow'], failures }, null, 2));
    console.log('Browser smoke passed: ' + out);
  } catch (error) {
    await page.screenshot({ path: out + '/failure.png' });
    fs.writeFileSync(out + '/failure.txt', await page.locator('body').innerText());
    throw error;
  } finally { await browser.close(); }
})().catch((error) => { console.error(error); process.exitCode = 1; });
