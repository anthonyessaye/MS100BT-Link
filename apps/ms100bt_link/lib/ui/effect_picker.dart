import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:zoom_core/zoom_core.dart';

import '../app_model.dart';
import 'native_ui.dart';
import 'widgets.dart';

/// Effect picker: categories, then effects drawn as mini stompboxes. Port of EffectLibrarySheet.
/// Returns the chosen effect ID (0 = remove from the slot), or null.
class EffectPicker extends StatefulWidget {
  const EffectPicker({super.key, required this.model, required this.slot});
  final AppModel model;
  final int slot;

  static Future<int?> show(BuildContext context, AppModel model, int slot) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    if (isMac) return showSheet<int>(context, EffectPicker(model: model, slot: slot), size: const Size(980, 660));
    if (wide) {
      return showDialog<int>(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: AppColors.background,
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 980,
            height: 660,
            child: EffectPicker(model: model, slot: slot),
          ),
        ),
      );
    }
    return Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => EffectPicker(model: model, slot: slot),
      ),
    );
  }

  @override
  State<EffectPicker> createState() => _EffectPickerState();
}

class _Item {
  const _Item(this.id, this.name, this.category, this.parameters);
  final int id;
  final String name, category;
  final List<String> parameters;
}

class _EffectPickerState extends State<EffectPicker> {
  String query = '';
  String? category; // null = all

  /// The MS-100BT's documented effects plus any effect already seen in this pedal's patches.
  late final List<_Item> all = () {
    final m = widget.model;
    final ids = {...EffectCatalog.ms100btEffectIds};
    for (final p in [...m.slots.values, if (m.patch != null) m.patch!]) {
      for (final e in p.effects.where((e) => !e.isEmpty)) {
        ids.add(e.effectId);
      }
    }
    return [
      for (final id in ids.toList()..sort())
        if (EffectCatalog.effect(id) case final e?)
          _Item(id, e.name, EffectCatalog.category(id) ?? 'Other', e.parameters.map((p) => p.name).toList()),
    ];
  }();

  List<(String, int)> get categories {
    final out = <String, int>{};
    for (final i in all) {
      out[i.category] = (out[i.category] ?? 0) + 1;
    }
    return out.entries.map((e) => (e.key, e.value)).toList(); // already in category-byte order (IDs sorted)
  }

  List<(String, List<_Item>)> get sections {
    final q = query.toLowerCase();
    final filtered = all.where(
      (i) =>
          (category == null || i.category == category) &&
          (q.isEmpty || i.name.toLowerCase().contains(q) || i.parameters.any((p) => p.toLowerCase().contains(q))),
    );
    return [
      for (final (c, _) in categories)
        if (filtered.where((i) => i.category == c).toList() case final items when items.isNotEmpty) (c, items),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final current = widget.model.patch?.effects[widget.slot];
    final grid = Column(
      children: [
        Container(
          color: AppColors.panel.withValues(alpha: 0.6),
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.search, color: AppColors.dim, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  autofocus: wide,
                  onChanged: (v) => setState(() => query = v),
                  style: const TextStyle(fontSize: 15),
                  decoration: const InputDecoration(border: InputBorder.none, hintText: 'Search effects or knobs (e.g. "delay", "tone")'),
                ),
              ),
              if (wide)
                Text(
                  'Slot ${widget.slot + 1}${current != null && !current.isEmpty ? ' · now ${current.displayName}' : ' · empty'}',
                  style: const TextStyle(color: AppColors.dim),
                ),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ],
          ),
        ),
        if (!wide)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [_chip(null, 'All'), for (final (c, _) in categories) _chip(c, c)],
            ),
          ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              for (final (cat, items) in sections)
                SliverMainAxisGroup(
                  slivers: [
                    // each header stays pinned only while its section scrolls
                    SliverPersistentHeader(pinned: true, delegate: _Header(cat, items.length)),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                      sliver: SliverGrid(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 160,
                          mainAxisSpacing: 18,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.72,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) => _Tile(
                            item: items[i],
                            isCurrent: current?.effectId == items[i].id,
                            onTap: () => Navigator.pop(context, items[i].id),
                          ),
                          childCount: items.length,
                        ),
                      ),
                    ),
                  ],
                ),
              if (sections.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Text(
                      'No effects match "$query"',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.dim),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    final body = !wide
        ? grid
        : Row(
            children: [
              Container(
                width: 210,
                color: AppColors.panel,
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Effects', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    _categoryRow(null, 'All effects', all.length),
                    for (final (c, n) in categories) _categoryRow(c, c, n),
                    const Spacer(),
                    if (current != null && !current.isEmpty) _removeButton(),
                  ],
                ),
              ),
              Expanded(child: grid),
            ],
          );
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: wide
          ? null
          : AppBar(
              backgroundColor: AppColors.panel,
              title: Text('Effects for slot ${widget.slot + 1}'),
              actions: [if (current != null && !current.isEmpty) _removeButton()],
            ),
      body: body,
    );
  }

  Widget _removeButton() => TextButton.icon(
    style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
    onPressed: () => Navigator.pop(context, 0),
    icon: const Icon(Icons.delete_outline, size: 18),
    label: Text('Remove from slot ${widget.slot + 1}'),
  );

  Widget _chip(String? value, String title) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: ChoiceChip(
      label: Text(title),
      selected: category == value,
      avatar: CircleAvatar(radius: 5, backgroundColor: value == null ? Colors.white60 : AppColors.category(value)),
      onSelected: (_) => setState(() => category = value),
    ),
  );

  Widget _categoryRow(String? value, String title, int count) {
    final on = category == value;
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: () => setState(() => category = value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
        decoration: BoxDecoration(color: on ? Colors.white.withValues(alpha: 0.09) : null, borderRadius: BorderRadius.circular(7)),
        child: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(shape: BoxShape.circle, color: value == null ? Colors.white60 : AppColors.category(value)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title, style: TextStyle(fontSize: 13, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
            ),
            Text('$count', style: const TextStyle(fontSize: 12, color: AppColors.dim)),
          ],
        ),
      ),
    );
  }
}

class _Header extends SliverPersistentHeaderDelegate {
  _Header(this.category, this.count);
  final String category;
  final int count;
  @override
  double get minExtent => 34;
  @override
  double get maxExtent => 34;
  @override
  bool shouldRebuild(_Header old) => old.category != category || old.count != count;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => Container(
    height: 34, // the header's child is laid out loosely; it must fill its extent
        color: const Color(0xF2171717),
    padding: const EdgeInsets.symmetric(horizontal: 18),
    child: Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.category(category)),
        ),
        const SizedBox(width: 8),
        Text(category.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
        const SizedBox(width: 8),
        Text('$count', style: const TextStyle(fontSize: 12, color: AppColors.dim)),
      ],
    ),
  );
}

/// One effect drawn as a small stompbox (EffectTile).
class _Tile extends StatefulWidget {
  const _Tile({required this.item, required this.isCurrent, required this.onTap});
  final _Item item;
  final bool isCurrent;
  final VoidCallback onTap;
  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final knobs = math.min(item.parameters.length, 3);
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: hover ? 1.04 : 1,
          duration: const Duration(milliseconds: 120),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: widget.isCurrent
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white, width: 2),
                        )
                      : null,
                  padding: const EdgeInsets.all(2),
                  child: PedalBody(
                    color: AppColors.category(item.category),
                    radius: 14,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(color: const Color(0x40000000), borderRadius: BorderRadius.circular(8)),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                for (var i = 0; i < math.max(knobs, 1); i++)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 3),
                                    child: Opacity(opacity: knobs == 0 ? 0 : 1, child: _KnobGlyph(const [-50.0, 20.0, 70.0][i % 3])),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Led(on: widget.isCurrent || hover, size: 7),
                          const SizedBox(height: 6),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              item.name,
                              maxLines: 1,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Colors.white),
                            ),
                          ),
                          const Spacer(),
                          const Footswitch(onTap: null, size: 26),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item.parameters.take(4).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: AppColors.dim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KnobGlyph extends StatelessWidget {
  const _KnobGlyph(this.angle);
  final double angle;
  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: angle * math.pi / 180,
    child: Container(
      width: 22,
      height: 22,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(center: Alignment(-0.3, -0.4), colors: [Color(0xFF525252), Color(0xFF1A1A1A)]),
      ),
      alignment: Alignment.topCenter,
      child: Container(width: 2, height: 8, margin: const EdgeInsets.only(top: 2), color: Colors.white),
    ),
  );
}
