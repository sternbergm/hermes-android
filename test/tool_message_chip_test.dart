import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/tool_message_chip.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders a collapsed chip and hides tool detail by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const ToolMessageChip(
          message: {
            'role': 'tool',
            'tool': 'execute_code',
            'content': 'SECRET_FULL_OUTPUT',
          },
        ),
      ),
    );

    // The compact label is shown...
    expect(find.text('execute_code — done'), findsOneWidget);
    // ...but the full tool output stays collapsed.
    expect(find.text('SECRET_FULL_OUTPUT'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });

  testWidgets('tapping the chip expands and collapses the detail', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const ToolMessageChip(
          message: {
            'role': 'tool',
            'tool': 'execute_code',
            'content': 'SECRET_FULL_OUTPUT',
          },
        ),
      ),
    );

    await tester.tap(find.text('execute_code — done'));
    await tester.pumpAndSettle();

    expect(find.text('SECRET_FULL_OUTPUT'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);

    // Tapping again collapses it back.
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    expect(find.text('SECRET_FULL_OUTPUT'), findsNothing);
  });

  testWidgets('shows a running status while a tool is still in progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const ToolMessageChip(
          message: {
            'role': 'tool_progress',
            'tool': 'browser_navigate',
            'status': 'running',
          },
        ),
      ),
    );

    expect(find.text('browser_navigate — running'), findsOneWidget);
  });
}
