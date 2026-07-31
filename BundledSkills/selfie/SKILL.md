---
name: selfie
description: Create a photorealistic self-portrait or selfie with WillDeep's image tools, optionally preserving a user-provided reference image. Use when the user asks to generate or edit a selfie, avatar, or personal portrait.
---

# Selfie and Portrait Generation

Use WillDeep's supported image paths:

- No reference image: call `generate_image`.
- User attachment or existing portrait to preserve: call `edit_generated_image`.
- Several source photos or identity-critical consistency needs: explain the current single-reference limitation and ask the user to choose the best source.

## Workflow

1. Confirm whose portrait is being created and whether a reference image is available.
2. Describe framing, pose, expression, clothing, scene, lighting, camera style, and required unchanged identity details.
3. For photorealism, explicitly request a natural photograph, realistic skin texture, plausible lighting, and a camera/lens treatment.
4. Submit one generation or edit task.
5. Return the resulting artifact through WillDeep.

Treat reference photos as private. Do not maintain a hidden album, infer an “owner,” expose another person's images, or claim access to identity data not supplied in the current context. Follow the active image provider's safety rules and never promise an unrestricted generation path.
