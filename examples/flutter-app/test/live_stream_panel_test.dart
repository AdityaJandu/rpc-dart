import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trpc_dart/trpc_dart.dart';

import 'package:example_flutter_app/main.dart';

void main() {
  // flutter_test intercepts HttpClient, so the panel is driven by a fake
  // stream factory instead of the live server.
  testWidgets('LiveStreamPanel renders incoming stream events', (tester) async {
    final events = StreamController<Map<String, Object?>>();
    void Function(int, Object?)? reconnectHook;
    final panel = LiveStreamPanel(
      title: 'activity feed',
      streamFactory: ({lastEventId, onReconnect}) {
        reconnectHook = onReconnect;
        return events.stream;
      },
      describe: (data) => '${data['message']}',
    );

    await tester.pumpWidget(
      ColoredBox(
        color: const Color(0xFF000000),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: panel,
        ),
      ),
    );

    // The panel opens its stream in initState: connecting first.
    expect(find.text('connecting...'), findsOneWidget);

    events
      ..add({'message': 'task created'})
      ..add({'message': 'note updated'});
    await tester.pumpAndSettle();

    expect(find.text('activity feed'), findsOneWidget);
    expect(find.text('note updated'), findsOneWidget);
    expect(find.text('connecting...'), findsNothing);

    // A scheduled reconnect surfaces the reconnecting label.
    reconnectHook!(1, RpcNetworkException('dropped'));
    await tester.pumpAndSettle();
    expect(find.text('reconnecting...'), findsOneWidget);

    events.add({'message': 'back online'});
    await tester.pumpAndSettle();
    expect(find.text('back online'), findsOneWidget);

    // Stream closes -> done status.
    await events.close();
    await tester.pumpAndSettle();
    expect(find.text('stream completed'), findsOneWidget);
  });
}
