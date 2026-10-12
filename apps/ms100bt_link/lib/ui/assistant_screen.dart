import 'package:flutter/material.dart';

import '../ai_assistant.dart';
import '../app_model.dart';
import 'dialogs.dart';
import 'widgets.dart';

/// Tone assistant chat. Port of the Mac AssistantPanel.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.model, required this.ai, this.onClose});
  final AppModel model;
  final AIAssistant ai;

  /// Set when docked as the right sidebar (wide screens), as on the Mac.
  final VoidCallback? onClose;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  AIAssistant get ai => widget.ai;
  final input = TextEditingController();
  final scroll = ScrollController();

  static const examples = [
    'A warm blues crunch with a touch of room reverb',
    'Shimmery ambient clean for slow chords',
    'Make the current patch darker',
    '80s chorus clean, tempo 96',
  ];

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    final t = text ?? input.text;
    if (t.trim().isEmpty) return;
    input.clear();
    ai.send(t);
    Future<void>.delayed(const Duration(milliseconds: 100), _toEnd);
  }

  void _toEnd() {
    if (scroll.hasClients) scroll.animateTo(scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([ai, widget.model]),
        builder: (context, _) => Scaffold(
          backgroundColor: AppColors.panel,
          appBar: widget.onClose == null
              ? AppBar(
                  backgroundColor: AppColors.panel,
                  title: Text('Tone Assistant · ${ai.provider.shortLabel}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  actions: _headerActions(),
                )
              : PreferredSize(
                  preferredSize: const Size.fromHeight(44),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
                    child: Row(children: [
                      const Icon(Icons.auto_awesome, size: 16, color: AppColors.accent),
                      const SizedBox(width: 6),
                      Expanded(child: Text('Tone Assistant · ${ai.provider.shortLabel}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                      ..._headerActions(),
                      IconButton(onPressed: widget.onClose, icon: const Icon(Icons.close, size: 16, color: AppColors.dim)),
                    ]),
                  ),
                ),
          body: !ai.keyLoaded
              ? const Center(child: CircularProgressIndicator())
              : !ai.isConfigured
                  ? _setup()
                  : Column(children: [
                      Expanded(
                        child: ai.items.isEmpty
                            ? _empty()
                            : ListView.builder(
                                controller: scroll,
                                padding: const EdgeInsets.all(12),
                                itemCount: ai.items.length + (ai.busy ? 1 : 0),
                                itemBuilder: (context, i) => i == ai.items.length
                                    ? const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator(color: AppColors.accent))
                                    : _item(ai.items[i]),
                              ),
                      ),
                      _composer(),
                    ]),
        ),
      );

  List<Widget> _headerActions() => [
        IconButton(tooltip: 'New conversation', iconSize: 18, onPressed: ai.items.isEmpty ? null : ai.reset, icon: const Icon(Icons.add_comment_outlined)),
        IconButton(tooltip: 'Settings', iconSize: 18, onPressed: () => _settings(context), icon: const Icon(Icons.tune)),
      ];

  Widget _setup() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.auto_awesome, size: 48, color: AppColors.accent),
              const SizedBox(height: 12),
              const Text('Describe a sound, get a patch', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
                'The assistant reads your pedal and proposes patches. Nothing reaches the pedal until you tap Try, '
                'and nothing is stored until you store it. Add an API key to start; it stays in this device\'s secure storage.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.dim),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(onPressed: () => _settings(context), icon: const Icon(Icons.key), label: const Text('Set up')),
            ]),
          ),
        ),
      );

  Widget _empty() => ListView(padding: const EdgeInsets.all(24), children: [
        const Text('Try one of these:', style: TextStyle(color: AppColors.dim)),
        const SizedBox(height: 8),
        for (final e in examples)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ActionChip(label: Text(e), onPressed: () => _send(e)),
          ),
      ]);

  Widget _item(ChatItem item) => switch (item.kind) {
        ChatKind.user => Align(
            alignment: Alignment.centerRight,
            child: _bubble(item.text, AppColors.accent.withValues(alpha: 0.25)),
          ),
        ChatKind.assistant => Align(alignment: Alignment.centerLeft, child: _bubble(item.text, AppColors.panelRaised)),
        ChatKind.activity => Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
            child: Row(children: [
              const Icon(Icons.check_circle_outline, size: 14, color: AppColors.dim),
              const SizedBox(width: 6),
              Expanded(child: Text(item.text, style: const TextStyle(color: AppColors.dim, fontSize: 12))),
            ]),
          ),
        ChatKind.error => Padding(
            padding: const EdgeInsets.all(8),
            child: Text(item.text, style: const TextStyle(color: Colors.redAccent)),
          ),
        ChatKind.proposal => _proposal(ai.proposals[item.proposalId]),
      };

  Widget _bubble(String text, Color color) => Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: SelectableText(text),
      );

  Widget _proposal(Proposal? p) {
    if (p == null) return const SizedBox.shrink();
    final patch = p.patch;
    return Card(
      color: AppColors.panel,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome, color: AppColors.accent, size: 18),
            const SizedBox(width: 6),
            Expanded(child: Text(patch.name?.trim() ?? 'Patch', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
            if (patch.tempo != null) Text('${patch.tempo} BPM', style: const TextStyle(color: AppColors.dim)),
          ]),
          const SizedBox(height: 8),
          for (final fx in patch.effects.where((e) => !e.isEmpty))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(width: 4, height: 30, color: fx.isOn == true ? AppColors.category(fx.category) : AppColors.dim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: '${fx.displayName}${fx.isOn == true ? '' : ' (off)'}\n', style: const TextStyle(fontWeight: FontWeight.w700)),
                    TextSpan(
                        text: fx.parameters.map((v) => '${v.name} ${v.text}').join(' · '),
                        style: const TextStyle(color: AppColors.dim, fontSize: 12)),
                  ])),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          switch (p.state) {
            ProposalState.proposed => Row(children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black),
                  onPressed: widget.model.canInteract ? () => _try(p) : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Try on pedal'),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: () => ai.discard(p.id), child: const Text('Discard')),
              ]),
            ProposalState.sending => const LinearProgressIndicator(color: AppColors.accent),
            ProposalState.onPedal => const Text("Playing on the pedal (not stored: store it from Patches if you like it).",
                style: TextStyle(color: Colors.green)),
            ProposalState.failed => Text('Not applied: ${p.failure}', style: const TextStyle(color: Colors.redAccent)),
            ProposalState.discarded => const Text('Discarded', style: TextStyle(color: AppColors.dim)),
          },
        ]),
      ),
    );
  }

  Future<void> _try(Proposal p) async {
    if (await ensureUnlocked(context, widget.model)) await ai.tryOnPedal(p.id);
  }

  Widget _composer() => SafeArea(
        top: false,
        child: Container(
          color: AppColors.panelRaised,
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(hintText: 'Describe a sound or a change…', border: InputBorder.none),
              ),
            ),
            ai.busy
                ? IconButton(tooltip: 'Stop', onPressed: ai.stop, icon: const Icon(Icons.stop_circle_outlined))
                : IconButton(tooltip: 'Send', onPressed: _send, icon: const Icon(Icons.send, color: AppColors.accent)),
          ]),
        ),
      );

  Future<void> _settings(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.panel,
        builder: (c) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
          child: _AssistantSettings(ai: ai, model: widget.model),
        ),
      );
}

class _AssistantSettings extends StatefulWidget {
  const _AssistantSettings({required this.ai, required this.model});
  final AIAssistant ai;
  final AppModel model;

  @override
  State<_AssistantSettings> createState() => _AssistantSettingsState();
}

class _AssistantSettingsState extends State<_AssistantSettings> {
  final key = TextEditingController();
  late final url = TextEditingController(text: widget.ai.baseUrl);
  late final custom = TextEditingController(text: widget.ai.model);

  @override
  void dispose() {
    key.dispose();
    url.dispose();
    custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.ai,
        builder: (context, _) {
          final ai = widget.ai;
          final ids = ai.models.map((m) => m.id).toList();
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Assistant settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              DropdownButtonFormField<AIProvider>(
                initialValue: ai.provider,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Provider'),
                items: [for (final p in AIProvider.values) DropdownMenuItem(value: p, child: Text(p.label, overflow: TextOverflow.ellipsis))],
                onChanged: (p) async {
                  if (p == null) return;
                  await ai.switchProvider(p);
                  url.text = ai.baseUrl;
                  custom.text = ai.model;
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: key,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: ai.provider.needsKey ? 'API key' : 'API key (optional)',
                  helperText: ai.hasKey ? 'A key is saved in secure storage. Enter a new one to replace it.' : null,
                  suffixIcon: IconButton(icon: const Icon(Icons.check), onPressed: () => ai.setApiKey(key.text)),
                ),
                onSubmitted: ai.setApiKey,
              ),
              if (ai.hasKey) TextButton(onPressed: () => ai.setApiKey(''), child: const Text('Remove saved key')),
              if (ai.provider != AIProvider.anthropic) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: url,
                  decoration: const InputDecoration(labelText: 'Base URL'),
                  onSubmitted: (v) {
                    ai.setBaseUrl(v);
                    ai.refreshModels();
                  },
                ),
              ],
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: ids.isEmpty
                      ? TextField(
                          controller: custom,
                          decoration: const InputDecoration(labelText: 'Model'),
                          onSubmitted: ai.setModel,
                        )
                      : DropdownButtonFormField<String>(
                          initialValue: ids.contains(ai.model) ? ai.model : null,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Model'),
                          items: [for (final m in ai.models) DropdownMenuItem(value: m.id, child: Text(m.name, overflow: TextOverflow.ellipsis))],
                          onChanged: (v) => v == null ? null : ai.setModel(v),
                        ),
                ),
                IconButton(
                  tooltip: 'Refresh models',
                  onPressed: ai.modelsLoading ? null : ai.refreshModels,
                  icon: ai.modelsLoading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh),
                ),
              ]),
              if (ai.modelsError != null) Text(ai.modelsError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: ai.autoTry,
                onChanged: ai.setAutoTry,
                title: const Text('Try proposals on the pedal automatically'),
                subtitle: const Text("Only while editing is unlocked. They go to the edit buffer; nothing is stored."),
              ),
            ]),
          );
        },
      );
}
