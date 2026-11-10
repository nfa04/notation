import 'package:flutter/material.dart';

import '../l10n/language.dart';
import '../models/canvas_models.dart';
import '../models/layers.dart';
import '../style/platform_dialog.dart';

/// The layers of a note: choose the one to draw on, show, hide, lock, rename, reorder, make see-through, add and delete them, and
/// move the selected drawings onto one. Every change is handed to [onChanged] as it is made, so the page behind shows it.
class LayersDialog extends StatefulWidget {
  final LayerStack layers;

  /// The layer lines are drawn on.
  final String active;

  /// How many drawings are selected (the menu of a layer can move them onto it).
  final int selectedCount;
  final void Function(LayerStack layers, String active) onChanged;
  final void Function(String layerId) onMoveSelection;

  const LayersDialog({super.key, required this.layers, required this.active, required this.selectedCount, required this.onChanged, required this.onMoveSelection});

  @override
  State<LayersDialog> createState() => _LayersDialogState();
}

class _LayersDialogState extends State<LayersDialog> {
  late LayerStack _layers = widget.layers;
  late String _active = _layers.byId(widget.active).id;

  void _change(LayerStack layers, String active) {
    setState(() {
      _layers = layers;
      _active = layers.byId(active).id;
    });
    widget.onChanged(_layers, _active);
  }

  @override
  Widget build(BuildContext context) {
    return PlatformAlertDialog(
      title: Text(tr('Layers')),
      content: SizedBox(
        width: 360,
        child: LayersList(layers: _layers, active: _active, selectedCount: widget.selectedCount, onChanged: _change, onMoveSelection: widget.onMoveSelection, shrinkWrap: true),
      ),
      actions: [
        _AddLayerButton(layers: _layers, active: _active, onChanged: _change),
        TextButton(key: const ValueKey('layers-done'), onPressed: () => Navigator.pop(context), child: Text(tr('Done'))),
      ],
    );
  }
}

/// The layers beside the note (on a wide screen): the same list as the dialog, but it follows the note as it changes - the layer
/// that is drawn on, how many drawings are selected - and stays open while the person draws.
class LayersPanel extends StatelessWidget {
  final LayerStack layers;
  final String active;
  final int selectedCount;
  final void Function(LayerStack layers, String active) onChanged;
  final void Function(String layerId) onMoveSelection;
  final VoidCallback onClose;

  const LayersPanel({super.key, required this.layers, required this.active, required this.selectedCount, required this.onChanged, required this.onMoveSelection, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(children: [
            Expanded(child: Text(tr('Layers'), style: Theme.of(context).textTheme.titleMedium)),
            IconButton(key: const ValueKey('layers-close'), tooltip: tr('Close'), icon: const Icon(Icons.close), onPressed: onClose),
          ]),
        ),
        Expanded(child: LayersList(layers: layers, active: active, selectedCount: selectedCount, onChanged: onChanged, onMoveSelection: onMoveSelection)),
        Padding(padding: const EdgeInsets.all(8), child: _AddLayerButton(layers: layers, active: active, onChanged: onChanged)),
      ]),
    );
  }
}

enum _Action { rename, up, down, move, delete }

/// "Add layer": a new layer above the one being drawn on, which is then the one drawn on.
class _AddLayerButton extends StatelessWidget {
  final LayerStack layers;
  final String active;
  final void Function(LayerStack layers, String active) onChanged;
  const _AddLayerButton({required this.layers, required this.active, required this.onChanged});

  /// "Layer 3": the next number that no layer has.
  String _newName() {
    final taken = {for (final l in layers.layers) l.name};
    for (var n = layers.length + 1;; n++) {
      final name = tr('Layer {n}', {'n': '$n'});
      if (!taken.contains(name)) return name;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: const ValueKey('layer-add'),
      icon: const Icon(Icons.add, size: 18),
      label: Text(tr('Add layer')),
      onPressed: layers.length >= maxLayers
          ? null
          : () {
              final layer = NoteLayer(newElementId(), _newName());
              onChanged(layers.added(layer, above: layers.indexOf(active)), layer.id);
            },
    );
  }
}

/// The rows of the layers, the top layer first: choose the one to draw on, show, hide, lock, rename, reorder, make see-through, delete.
/// Every change goes to [onChanged] with the layer that is drawn on; the caller holds the state.
class LayersList extends StatelessWidget {
  final LayerStack layers;
  final String active;
  final int selectedCount;
  final void Function(LayerStack layers, String active) onChanged;
  final void Function(String layerId) onMoveSelection;
  final bool shrinkWrap;

  const LayersList({super.key, required this.layers, required this.active, required this.selectedCount, required this.onChanged, required this.onMoveSelection, this.shrinkWrap = false});

  Future<void> _rename(BuildContext context, NoteLayer layer) async {
    final controller = TextEditingController(text: layer.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text(tr('Rename layer')),
        content: TextField(key: const ValueKey('layer-rename-field'), controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
          TextButton(key: const ValueKey('layer-rename-ok'), onPressed: () => Navigator.pop(context, controller.text), child: Text(tr('OK'))),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    onChanged(layers.replaced(layer.copyWith(name: name.trim())), active);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = layers.byId(active).id;
    // the top layer first, as a stack of sheets is read
    final shown = layers.layers.reversed.toList();
    return ListView(
      shrinkWrap: shrinkWrap,
      children: [
        for (final layer in shown) ...[
          Container(
            key: ValueKey('layer-row-${layer.id}'),
            decoration: BoxDecoration(color: layer.id == current ? scheme.secondaryContainer : null, borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              IconButton(
                key: ValueKey('layer-visible-${layer.id}'),
                tooltip: tr(layer.visible ? 'Hide layer' : 'Show layer'),
                icon: Icon(layer.visible ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
                onPressed: () => onChanged(layers.replaced(layer.copyWith(visible: !layer.visible)), current),
              ),
              IconButton(
                key: ValueKey('layer-lock-${layer.id}'),
                tooltip: tr(layer.locked ? 'Unlock layer' : 'Lock layer'),
                icon: Icon(layer.locked ? Icons.lock_outline : Icons.lock_open_outlined, size: 20),
                onPressed: () => onChanged(layers.replaced(layer.copyWith(locked: !layer.locked)), current),
              ),
              Expanded(
                child: InkWell(
                  key: ValueKey('layer-${layer.id}'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onChanged(layers, layer.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                    child: Text(tr(layer.name), overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: layer.id == current ? FontWeight.w600 : null, color: layer.visible ? null : Theme.of(context).disabledColor)),
                  ),
                ),
              ),
              PopupMenuButton<_Action>(
                key: ValueKey('layer-menu-${layer.id}'),
                tooltip: tr('More'),
                onSelected: (a) {
                  switch (a) {
                    case _Action.rename:
                      _rename(context, layer);
                    case _Action.up:
                      onChanged(layers.moved(layer.id, 1), current);
                    case _Action.down:
                      onChanged(layers.moved(layer.id, -1), current);
                    case _Action.move:
                      onMoveSelection(layer.id);
                    case _Action.delete:
                      onChanged(layers.without(layer.id), current);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(value: _Action.rename, child: Text(tr('Rename'))),
                  PopupMenuItem(value: _Action.up, enabled: layers.layers.last.id != layer.id, child: Text(tr('Move up'))),
                  PopupMenuItem(value: _Action.down, enabled: layers.layers.first.id != layer.id, child: Text(tr('Move down'))),
                  if (selectedCount > 0) PopupMenuItem(value: _Action.move, child: Text(tr('Move the selected drawings here'))),
                  if (layer.id != baseLayerId) PopupMenuItem(value: _Action.delete, child: Text(tr('Delete (its drawings go to the bottom layer)'))),
                ],
              ),
            ]),
          ),
          if (layer.id == current)
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12),
              child: Row(children: [
                Text(tr('Opacity'), style: Theme.of(context).textTheme.bodySmall),
                Expanded(
                  child: Slider.adaptive(
                    key: const ValueKey('layer-opacity'),
                    value: layer.opacity,
                    min: 0.05,
                    onChanged: (v) => onChanged(layers.replaced(layer.copyWith(opacity: v)), current),
                  ),
                ),
                SizedBox(width: 40, child: Text('${(layer.opacity * 100).round()}%', style: Theme.of(context).textTheme.bodySmall)),
              ]),
            ),
        ],
      ],
    );
  }
}
