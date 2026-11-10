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

enum _Action { rename, up, down, move, delete, newGroup, intoGroup, outOfGroup }

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

/// The rows of the layers, the top layer first (a group, then its layers, a little in): choose the one to draw on, show, hide, lock,
/// rename, reorder, make see-through, lay over the others by a blend mode, clip to the layer below, group, delete.
/// Every change goes to [onChanged] with the layer that is drawn on; the caller holds the state.
class LayersList extends StatefulWidget {
  final LayerStack layers;
  final String active;
  final int selectedCount;
  final void Function(LayerStack layers, String active) onChanged;
  final void Function(String layerId) onMoveSelection;
  final bool shrinkWrap;

  const LayersList({super.key, required this.layers, required this.active, required this.selectedCount, required this.onChanged, required this.onMoveSelection, this.shrinkWrap = false});

  @override
  State<LayersList> createState() => _LayersListState();
}

class _LayersListState extends State<LayersList> {
  /// The group whose settings are shown (a tap on a group), until a layer is chosen.
  String? _openGroup;

  LayerStack get layers => widget.layers;

  Future<void> _rename(BuildContext context, NoteLayer layer) async {
    final controller = TextEditingController(text: layer.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text(tr(layer.isGroup ? 'Rename group' : 'Rename layer')),
        content: TextField(key: const ValueKey('layer-rename-field'), controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
          TextButton(key: const ValueKey('layer-rename-ok'), onPressed: () => Navigator.pop(context, controller.text), child: Text(tr('OK'))),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    widget.onChanged(layers.replaced(layer.copyWith(name: name.trim())), widget.active);
  }

  /// "Group 2": the next number that no layer has.
  String _newGroupName() {
    final taken = {for (final l in layers.layers) l.name};
    for (var n = 1;; n++) {
      final name = tr('Group {n}', {'n': '$n'});
      if (!taken.contains(name)) return name;
    }
  }

  void _act(_Action a, String? other, NoteLayer layer, String current) {
    switch (a) {
      case _Action.rename:
        _rename(context, layer);
      case _Action.up:
        widget.onChanged(layers.moved(layer.id, 1), current);
      case _Action.down:
        widget.onChanged(layers.moved(layer.id, -1), current);
      case _Action.move:
        widget.onMoveSelection(layer.id);
      case _Action.delete:
        widget.onChanged(layers.without(layer.id), current);
      case _Action.newGroup:
        widget.onChanged(layers.groupedWith(layer.id, newElementId(), _newGroupName()), current);
      case _Action.intoGroup:
        widget.onChanged(layers.inGroup(layer.id, other ?? ''), current);
      case _Action.outOfGroup:
        widget.onChanged(layers.inGroup(layer.id, ''), current);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = layers.byId(widget.active).id;
    final open = _openGroup != null && layers.layers.any((l) => l.id == _openGroup && l.isGroup) ? _openGroup : null;
    final settingsFor = open ?? current;
    // the top layer first, as a stack of sheets is read; a group comes before its layers
    final shown = <NoteLayer>[];
    for (final i in layers.topLevel.reversed) {
      final l = layers.layers[i];
      shown.add(l);
      if (l.isGroup && !l.collapsed) shown.addAll([for (final m in layers.membersOf(l.id).reversed) layers.layers[m]]);
    }
    final groups = [for (final l in layers.layers) if (l.isGroup) l];
    return ListView(
      shrinkWrap: widget.shrinkWrap,
      children: [
        for (final layer in shown) ...[
          Container(
            key: ValueKey('layer-row-${layer.id}'),
            margin: EdgeInsets.only(left: layer.group.isEmpty ? 0 : 20),
            decoration: BoxDecoration(color: layer.id == settingsFor ? scheme.secondaryContainer : null, borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              IconButton(
                key: ValueKey('layer-visible-${layer.id}'),
                tooltip: tr(layer.visible ? 'Hide layer' : 'Show layer'),
                icon: Icon(layer.visible ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
                onPressed: () => widget.onChanged(layers.replaced(layer.copyWith(visible: !layer.visible)), current),
              ),
              IconButton(
                key: ValueKey('layer-lock-${layer.id}'),
                tooltip: tr(layer.locked ? 'Unlock layer' : 'Lock layer'),
                icon: Icon(layer.locked ? Icons.lock_outline : Icons.lock_open_outlined, size: 20),
                onPressed: () => widget.onChanged(layers.replaced(layer.copyWith(locked: !layer.locked)), current),
              ),
              if (layer.isGroup)
                IconButton(
                  key: ValueKey('group-fold-${layer.id}'),
                  tooltip: tr(layer.collapsed ? 'Show the layers of the group' : 'Fold the group'),
                  icon: Icon(layer.collapsed ? Icons.folder_outlined : Icons.folder_open_outlined, size: 20),
                  onPressed: () => widget.onChanged(layers.replaced(layer.copyWith(collapsed: !layer.collapsed)), current),
                ),
              Expanded(
                child: InkWell(
                  key: ValueKey('layer-${layer.id}'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    if (layer.isGroup) {
                      setState(() => _openGroup = layer.id);
                    } else {
                      setState(() => _openGroup = null);
                      widget.onChanged(layers, layer.id);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                    child: Text(tr(layer.name),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: layer.id == (layer.isGroup ? open : current) ? FontWeight.w600 : null, color: layer.visible ? null : Theme.of(context).disabledColor)),
                  ),
                ),
              ),
              PopupMenuButton<(_Action, String?)>(
                key: ValueKey('layer-menu-${layer.id}'),
                tooltip: tr('More'),
                onSelected: (a) => _act(a.$1, a.$2, layer, current),
                itemBuilder: (context) => [
                  PopupMenuItem(value: (_Action.rename, null), child: Text(tr('Rename'))),
                  PopupMenuItem(value: (_Action.up, null), enabled: layer.group.isEmpty ? layers.topLevel.last != layers.indexOf(layer.id) : layers.membersOf(layer.group).last != layers.indexOf(layer.id), child: Text(tr('Move up'))),
                  PopupMenuItem(value: (_Action.down, null), enabled: layer.group.isEmpty ? layers.topLevel.first != layers.indexOf(layer.id) : layers.membersOf(layer.group).first != layers.indexOf(layer.id), child: Text(tr('Move down'))),
                  if (selectedCount > 0 && !layer.isGroup) PopupMenuItem(value: (_Action.move, null), child: Text(tr('Move the selected drawings here'))),
                  if (!layer.isGroup && layer.id != baseLayerId) ...[
                    PopupMenuItem(key: ValueKey('layer-new-group-${layer.id}'), value: (_Action.newGroup, null), child: Text(tr('Put in a new group'))),
                    for (final g in groups)
                      if (g.id != layer.group) PopupMenuItem(value: (_Action.intoGroup, g.id), child: Text(tr('Put in the group "{name}"', {'name': tr(g.name)}))),
                    if (layer.group.isNotEmpty) PopupMenuItem(value: (_Action.outOfGroup, null), child: Text(tr('Take out of the group'))),
                  ],
                  if (layer.isGroup)
                    PopupMenuItem(key: ValueKey('group-ungroup-${layer.id}'), value: (_Action.delete, null), child: Text(tr('Ungroup (the layers stay)')))
                  else if (layer.id != baseLayerId)
                    PopupMenuItem(value: (_Action.delete, null), child: Text(tr('Delete (its drawings go to the bottom layer)'))),
                ],
              ),
            ]),
          ),
          if (layer.id == settingsFor) _settings(context, layer),
        ],
      ],
    );
  }

  int get selectedCount => widget.selectedCount;

  /// Under the chosen layer (or group): how see-through it is, how it lies over what is under it, and whether it is clipped.
  Widget _settings(BuildContext context, NoteLayer layer) {
    final current = layers.byId(widget.active).id;
    final text = Theme.of(context).textTheme.bodySmall;
    // (clipping is to the layer below in the same group: the lowest one has none)
    final siblings = layer.group.isEmpty ? layers.topLevel : layers.membersOf(layer.group);
    final canClip = siblings.isNotEmpty && siblings.first != layers.indexOf(layer.id) && layer.id != baseLayerId;
    return Padding(
      padding: EdgeInsets.only(left: layer.group.isEmpty ? 12 : 32, right: 12),
      child: Column(children: [
        Row(children: [
          Text(tr('Opacity'), style: text),
          Expanded(
            child: Slider.adaptive(
              key: const ValueKey('layer-opacity'),
              value: layer.opacity,
              min: 0.05,
              onChanged: (v) => widget.onChanged(layers.replaced(layer.copyWith(opacity: v)), current),
            ),
          ),
          SizedBox(width: 40, child: Text('${(layer.opacity * 100).round()}%', style: text)),
        ]),
        Row(children: [
          Text(tr('Blend mode'), style: text),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<LayerBlend>(
              key: const ValueKey('layer-blend'),
              isExpanded: true,
              isDense: true,
              value: layer.blend,
              items: [for (final b in LayerBlend.values) DropdownMenuItem(key: ValueKey('layer-blend-${b.name}'), value: b, child: Text(tr(b.label)))],
              onChanged: (b) => widget.onChanged(layers.replaced(layer.copyWith(blend: b)), current),
            ),
          ),
        ]),
        if (canClip)
          Row(children: [
            Expanded(child: Text(tr('Clip to the layer below (shows only where it has drawn)'), style: text)),
            Switch.adaptive(
              key: const ValueKey('layer-clip'),
              value: layer.clip,
              onChanged: (v) => widget.onChanged(layers.replaced(layer.copyWith(clip: v)), current),
            ),
          ]),
      ]),
    );
  }
}
