# Marp cheat-sheet (for writing deck.md)

Marp = Markdown that is *also* a slide deck. A plain `.md` viewer shows it as a document;
`marp` renders it to PPTX/PDF/HTML.

## Required frontmatter
```markdown
---
marp: true
theme: midnight-dark    # Midnight-dark house theme (assets/theme-midnight-dark.css). Also: default | gaia | uncover
paginate: true
size: 16:9
---
```

`midnight-dark` is registered automatically by `scripts/render.sh` (`marp --theme-set`). It
gives dark graphite slides with lime accents that match the diagram theme — see
`assets/design-tokens.md`.

## Slides
- Separate slides with a line containing only `---`.
- First `#` heading on a slide is its title.

## Per-slide directives (HTML comment at top of a slide)
```markdown
<!-- _class: lead -->        title/centered layout
<!-- _backgroundColor: #111 -->
<!-- _color: white -->
```

## Images (sizing keywords are Marp-specific)
```markdown
![w:600](frames/kf_0007.jpg)      fixed width 600px
![h:300](diagrams/d01.svg)        fixed height
![bg](img.jpg)                    full-slide background
![bg left:40%](img.jpg)           background on left 40%, text on right
```
When rendering with local images, run marp with `--allow-local-files` (render.sh already does).

## Speaker notes
Any HTML comment that is **not** a directive becomes speaker notes:
```markdown
<!-- This text is spoken-notes only; it doesn't show on the slide. -->
```

## Two columns (simple)
```markdown
<div class="columns">

- left column

- right column

</div>

<style>
.columns { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
</style>
```

## Render (see scripts/render.sh)
```bash
marp deck.md -o deck.pptx        # PowerPoint
marp deck.md --pdf               # PDF
marp deck.md --html              # self-contained HTML
```
