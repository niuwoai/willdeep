---
name: image-gen
description: Generate and edit images with WillDeep's built-in some.im image tools. Use for text-to-image, reference-image editing, background or object changes, masks, upscaling, and presenting several image candidates.
---

# Image Generation and Editing

## Choose the Correct Tool

- New image from text: `generate_image`
- Edit a user attachment or existing local image while preserving its subject: `edit_generated_image`
- Let the user paint a mask: `open_image_editor`
- Apply an existing mask: `edit_image_with_mask`
- Upscale a local image: `upscale_image`
- Present multiple local candidates: `show_image_choice_widget`

## Workflow

1. Determine whether the user wants a new image or an edit of a specific source.
2. For an edit, use the attachment path or generated-image reference already present in context. Do not ask for the same image again.
3. Write a detailed prompt covering subject, composition, style, lighting, materials, camera, and any elements that must remain unchanged.
4. Leave the model unset unless the user requests a specific available model.
5. Submit once and report the async task state honestly. Do not silently resubmit a failed or timed-out paid job.
6. Return the generated artifact through WillDeep's media result or a local Markdown image link.

Keep credentials in WillDeep Settings and Keychain. Never place API keys in prompts, files, logs, or command lines.
