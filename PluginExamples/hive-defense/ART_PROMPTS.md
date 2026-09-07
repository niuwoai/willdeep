# 透明素材生成记录

工具：内置 `image_gen`，每种素材独立生成一次，未使用 CLI/API 回退。输出为原生 alpha PNG，1254×1254；保留原文件像素，没有抠图或白底替换。运行时按比例绘制到小尺寸，独立资源只加载一次。

共同提示词约束：production game sprite for honeycomb tower-defense; top-down orthographic; charming polished hand-painted 2D game art; crisp dark outlines; chunky readable silhouette; centered isolated object with 12 percent transparent padding; square 512x512 PNG with genuine alpha transparency; no text, labels, scene, ground, tile or outside shadow. 生成器实际返回尺寸为 1254×1254。

| 文件 | 主体提示词 |
| --- | --- |
| sting.png | Worker-bee sentry turret; weapon aims exactly RIGHT; golden honey-yellow wax and dark brown compact mechanical bee-stinger gun on a small hexagonal honeycomb base. |
| bomb.png | Honey-propolis cannon turret; barrel points exactly RIGHT; copper-brown stout mortar barrel with amber resin reservoir and compact hexagonal wax base. |
| pollen.png | Pollen-spray tower; five rounded pale blue flower petals surrounding a pollen nozzle; small honeycomb hexagonal wax base; blue glass pollen reservoir; compact botanical defense machine. |
| barb.png | Poison-stinger crossbow turret; arrow points exactly RIGHT; purple thorn crossbow with curved bow arms; long sharp violet stinger arrow; compact hexagonal honeycomb wax base; small green poison vial. |
| drum.png | Resonance support tower; green botanical resonator with concentric emerald brass rings around a glowing honey crystal and compact hexagonal wax honeycomb base; no weapon. |
| aphid.png | Green aphid; head faces exactly RIGHT; plump pear-shaped light olive-green insect; six short legs; tiny antennae; dark eyes. |
| wasp.png | Yellow wasp; head faces exactly RIGHT; golden-yellow and dark brown striped slender abdomen; narrow waist; six legs; two pairs of delicate translucent wings spread symmetrically; antennae and stinger. |
| beetle.png | Armored beetle; head faces exactly RIGHT; stout steel-blue beetle with two rounded segmented hard wing covers; six dark legs; short antennae; tiny mandibles; subtle glossy armor. |
| moth.png | Moth; head faces exactly RIGHT; soft lavender and dusty mauve; broad triangular patterned wings spread symmetrically; fuzzy small body; feathery antennae. |
| spider.png | Spider; head faces exactly RIGHT; plum-brown spider with exactly eight articulated legs; two distinct rounded body segments; small amber eyes; clear leg separation. |
| hornet.png | Giant hornet BOSS; head faces exactly RIGHT; powerful red-orange hornet with dark brown striped armored abdomen; larger fierce mandibles; six legs; antennae; two pairs of translucent amber wings spread symmetrically; long stinger; no crown. |
| hive.png | Honeybee hive base; compact hexagonal cluster of golden beeswax honeycomb cells with amber honey centers; slightly raised central hive entrance; warm brown edges; no bees or other creatures. |

## 1.336.0-rc1 维修蜂

`ui/assets/repair-bee.png` 使用内置 imagegen 生成并编辑，保留 alpha，实际尺寸 1536×1024。

生成提示词：A single friendly honeybee repair worker game sprite with a tiny sky-blue mechanic cap and one small silver wrench held in its forelegs, golden yellow and brown striped round body, smiling friendly eyes, delicate translucent wings. Top-down three-quarter view with head to the right, whole bee and wrench inside image. Charming polished hand-painted 2D honeycomb tower-defense art, crisp dark outlines and chunky readable silhouette. One centered isolated character, no hive, no scenery, no lettering, no ground or outside shadow. Genuine transparent alpha PNG background, ample clear padding. Suitable for a small bee flying around a damaged hive to repair it.

编辑提示词：Keep exactly this cute repair bee, blue cap and wrench. Remove ALL background, all black or brown vignette, all atmospheric glow/haze around the bee, every surrounding shadow. Output a clean isolated game sprite with completely transparent pixels outside the bee, wrench and wings. The bee's body and hat must be fully opaque, wing membranes may be translucent. Do not add scenery, lighting halos, text or other objects. Preserve the same bee design and fit it entirely within generous transparent padding.
# 狗熊访客（1.337.0-rc1）

内置 imagegen 生成；最终文件 `ui/assets/bear.png`，保留原生透明 alpha，无后期抠图。

Prompt: Create one game sprite of a cute mischievous brown bear for a children's honeybee tower defense game. Whole body, chubby rounded silhouette, standing facing viewer slightly three-quarter, paws raised playfully, warm chestnut fur, beige muzzle and belly, small black eyes, cheerful determined expression. Charming polished hand-painted cartoon game illustration, warm earthy palette, crisp thick soft brown outlines, subtle volume. Single centered isolated character, large generous empty margins, no props, no text, no scenery, no shadow outside silhouette, no glow. True transparent alpha background PNG, not checkerboard. Used both at small size on map and as large aiming target in a non-graphic honey-ball minigame.
# 丛林瞄准背景（1.338.0-rc1）

内置 imagegen 生成，最终文件 `ui/assets/jungle.png`。此图为完整不透明场景，狗熊沿用透明角色图，放大镜直接采样同一画布。

Prompt: Wide landscape 16:9 background illustration for a children's forest aiming mini-game. Lush storybook jungle clearing, layered emerald and sage green leafy trees and vines along sides, warm soft sunlight coming through canopy, distant atmospheric trunks, gentle earth and moss floor occupying lower third, open uncluttered middle area with gentle green shrubs and depth where a cartoon brown bear will move horizontally. Polished warm hand-painted 2D casual game art, friendly and magical not scary, moderate detail, soft outlines, natural green gold palette. Background only, no bear or any animals, no characters, no text, no UI, no target, no crosshairs, no borders. Full bleed opaque landscape illustration.
# 三种新增虫群（1.339.0-rc1）

内置 imagegen 分别生成 `ui/assets/ant.png`、`caterpillar.png`、`grasshopper.png`，选用带真实 alpha 的初始输出。清边编辑候选没有改善透明输出，未采用。

共同提示词：Single isolated transparent PNG sprite of SUBJECT. Friendly children's honeybee tower defense enemy. Full body pointing to the RIGHT, top down three-quarter game view. Warm hand-painted cartoon style, crisp soft dark outlines, rounded readable silhouette, subtle shading, similar to polished casual garden tower-defense art. Centered full character with empty margin all around. True transparent alpha background. No text, no scenery, no ground, no glow, no cast shadow outside silhouette. One character only.

- ant SUBJECT: a reddish chestnut ant, six legs, three distinct body segments, big rounded abdomen, cute antennae
- caterpillar SUBJECT: a plump lime green caterpillar, segmented rounded body, tiny feet, small amber face, charming leaf-like markings
- grasshopper SUBJECT: a bright jade green grasshopper, long bent jumping hind legs, folded wings, tiny antennae
# 跳蚤（1.340.0-rc1）

内置 imagegen 生成 `ui/assets/flea.png`，原生透明 alpha，未后期抠图。

Prompt: A single cute amber-purple flea enemy sprite for a children's garden tower defense game. Full body side three-quarter view facing RIGHT, rounded tiny head, compact segmented reddish plum body, six legs with oversized spring-like bent hind legs, charming big eyes. Warm hand-painted casual game illustration, clean crisp dark outlines, softly shaded, readable at small size. Centered isolated character with empty margins. Real transparent PNG alpha background. No colored glow, no aura, no ground shadow, no fog, no text, no checkerboard pattern, no scenery, no background.
