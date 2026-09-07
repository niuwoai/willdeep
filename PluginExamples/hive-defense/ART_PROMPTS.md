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
