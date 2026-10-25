# Mac preview, undo and invoice summary

Approved: implement remaining three UI improvements. Cancel the per-invoice buyer-title editing plan.

- Add a resizable right preview pane for the selected visible order; support long-image scrolling, zoom and click-to-enlarge using the existing overlay. Pane can be hidden. Preserve table column order and editable fields.
- Add undo for order deletion and reordering using native UndoManager. Do not overwrite unrelated edits/imports. Clear history when switching drafts. Keep source files intact. Cmd+Z respects native text editing; explicit undo button operates on order actions.
- Show order total, valid invoice total, shortage/surplus and pending-confirmation count prominently, keeping current invoice calculations and export requirements.
- Keep baseline 1.10 and previous packages. No draft format migration or Windows update.
- Validate undo edge cases through isolated checks; compile/sign/package Mac 1.12; manual UI acceptance belongs to the user.
