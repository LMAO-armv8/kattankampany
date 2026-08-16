import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/config/app_info.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../routing/app_router.dart';
import '../controllers/pairing_controller.dart';

/// First-run screen: "Connect your store".
///
/// Two fields and one button. No WordPress username or password is requested —
/// the agent asks the store for a pairing code, and an administrator approves
/// the device in wp-admin. That is the entire trust handshake, and it is what
/// lets a warehouse operator run this without ever holding admin credentials.
class ConnectStoreScreen extends ConsumerStatefulWidget {
  const ConnectStoreScreen({super.key});

  @override
  ConsumerState<ConnectStoreScreen> createState() => _ConnectStoreScreenState();
}

class _ConnectStoreScreenState extends ConsumerState<ConnectStoreScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _storeUrl = TextEditingController();
  late final TextEditingController _agentName;

  @override
  void initState() {
    super.initState();
    _agentName = TextEditingController(
      text: ref.read(pairingControllerProvider.notifier).suggestedAgentName,
    );
  }

  @override
  void dispose() {
    _storeUrl.dispose();
    _agentName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    await ref.read(pairingControllerProvider.notifier).connect(
          storeUrl: _storeUrl.text,
          agentName: _agentName.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(pairingControllerProvider);

    ref.listen<PairingUiState>(pairingControllerProvider,
        (PairingUiState? previous, PairingUiState next) {
      if (next.completed && (previous?.completed ?? false) == false) {
        context.go(AppRoutes.dashboard);
      }
    });

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Header(theme: theme),
                const SizedBox(height: AppSpacing.xl),
                if (state.awaitingApproval)
                  _AwaitingApproval(state: state)
                else
                  _Form(
                    formKey: _formKey,
                    storeUrl: _storeUrl,
                    agentName: _agentName,
                    state: state,
                    onSubmit: _submit,
                  ),
                if (state.error != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  _ErrorBanner(message: state.error!.userMessage),
                ],
                const SizedBox(height: AppSpacing.xl),
                Text(
                  '${AppInfo.productName} · v${AppInfo.instance.version}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Column(
        children: <Widget>[
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.print_rounded, color: Colors.white, size: 30),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Connect your store',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Register this computer as a print agent. An administrator approves '
            'it once in your store — you will never be asked for a WordPress '
            'password.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      );
}

class _Form extends StatelessWidget {
  const _Form({
    required this.formKey,
    required this.storeUrl,
    required this.agentName,
    required this.state,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController storeUrl;
  final TextEditingController agentName;
  final PairingUiState state;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const _FieldLabel('Store URL'),
              TextFormField(
                controller: storeUrl,
                autofocus: true,
                enabled: !state.isConnecting,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  hintText: 'https://your-store.com',
                  prefixIcon: Icon(Icons.storefront_outlined, size: 20),
                ),
                validator: (String? value) =>
                    (value == null || value.trim().isEmpty)
                        ? 'Enter the address of your WooCommerce store'
                        : null,
              ),
              const SizedBox(height: AppSpacing.md),
              const _FieldLabel('Agent name'),
              TextFormField(
                controller: agentName,
                enabled: !state.isConnecting,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => onSubmit(),
                decoration: const InputDecoration(
                  hintText: 'Warehouse PC',
                  prefixIcon: Icon(Icons.computer_outlined, size: 20),
                ),
                validator: (String? value) =>
                    (value == null || value.trim().isEmpty)
                        ? 'Give this computer a name you will recognise'
                        : null,
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: state.isConnecting ? null : onSubmit,
                child: state.isConnecting
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AwaitingApproval extends ConsumerWidget {
  const _AwaitingApproval({required this.state});

  final PairingUiState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = state.session!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSpacing.sm + 4),
                Expanded(
                  child: Text(
                    state.message ?? 'Waiting for approval…',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Approval code',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            _PairingCode(code: session.pairingCode),
            const SizedBox(height: AppSpacing.md),
            Text(
              'In your store, go to WooCommerce → Print Management → Agents and '
              'approve the request showing this code.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (session.verificationUrl != null) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              OutlinedButton.icon(
                onPressed: () async {
                  final uri = Uri.tryParse(session.verificationUrl!);
                  if (uri != null) await launchUrl(uri);
                },
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open approval page'),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () =>
                  ref.read(pairingControllerProvider.notifier).cancel(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PairingCode extends StatelessWidget {
  const _PairingCode({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 14,
      ),
      decoration: BoxDecoration(
        color: colors.subtleBackground,
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SelectableText(
              code,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy code',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Approval code copied')),
                );
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        border: Border.all(color: colors.danger.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: colors.danger),
          const SizedBox(width: AppSpacing.sm + 2),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
