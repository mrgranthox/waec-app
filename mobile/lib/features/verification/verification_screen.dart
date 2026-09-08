import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';
import 'verification_providers.dart';

/// Unified verification screen — plan §3.3.
///
/// Index (10 digits), exam-type selector (BECE / WASSCE SC / Nwasie),
/// exam year, MoMo/card channel, CTA with dynamic server-driven price.
/// CTA disabled until the form is fully valid.
class VerificationScreen extends ConsumerWidget {
  const VerificationScreen({super.key, required this.onJourneyStart});

  final void Function() onJourneyStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = ref.watch(verificationFormProvider);
    final notifier = ref.read(verificationFormProvider.notifier);
    final priceAsync = ref.watch(priceProvider(form.examType));

    return Scaffold(
      appBar: AppBar(title: const Text('Verify Results')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(WaecSpacing.md),
          children: [
            Text('Candidate index number',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: WaecSpacing.xs),
            TextFormField(
              initialValue: form.indexNumber,
              keyboardType: TextInputType.number,
              maxLength: 10,
              decoration: const InputDecoration(
                hintText: 'e.g. 1002330440',
                counterText: '',
              ),
              onChanged: notifier.setIndex,
            ),
            const SizedBox(height: WaecSpacing.md),
            Text('Exam type', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: WaecSpacing.xs),
            SegmentedButton<ExamType>(
              segments: const [
                ButtonSegment(
                    value: ExamType.bece, label: Text('BECE')),
                ButtonSegment(
                    value: ExamType.wassceSchool,
                    label: Text('WASSCE SC')),
                ButtonSegment(
                    value: ExamType.wasscePrivate,
                    label: Text('Nwasie')),
              ],
              selected: {form.examType},
              onSelectionChanged: (s) => notifier.setExam(s.first),
            ),
            const SizedBox(height: WaecSpacing.md),
            Text('Exam year', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: WaecSpacing.xs),
            TextFormField(
              initialValue: form.examYear,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(hintText: '2025'),
              onChanged: notifier.setYear,
            ),
            const SizedBox(height: WaecSpacing.md),
            Text('Payment channel',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: WaecSpacing.xs),
            Wrap(
              spacing: WaecSpacing.sm,
              children: [
                for (final c in PaymentChannel.values)
                  ChoiceChip(
                    label: Text(c.displayName),
                    selected: form.channel == c,
                    onSelected: (_) => notifier.setChannel(c),
                  ),
              ],
            ),
            if (form.channel == PaymentChannel.mtnMomo) ...[
              const SizedBox(height: WaecSpacing.sm),
              TextFormField(
                keyboardType: TextInputType.phone,
                maxLength: 10,
                decoration: const InputDecoration(
                  hintText: 'MoMo number (0244000000)',
                  counterText: '',
                ),
                onChanged: notifier.setPhone,
              ),
            ],
            const SizedBox(height: WaecSpacing.xl),
            // CTA with dynamic server-driven price (plan §3.3).
            priceAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => FilledButton(
                onPressed: null,
                child: const Text('Price unavailable — retry'),
              ),
              data: (price) => FilledButton(
                // CTA disabled until valid (acceptance §3.3).
                onPressed: form.isValid
                    ? () {
                        ref.read(journeyProvider.notifier).start(
                              indexNumber: form.indexNumber,
                              examType: form.examType,
                              examYear: form.examYear,
                              channel: form.channel,
                              phone: form.phone,
                            );
                        onJourneyStart();
                      }
                    : null,
                child: Text('Pay ${price.display} & Retrieve'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
