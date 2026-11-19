import 'package:flutter/widgets.dart';
import 'package:orpc_flutter/orpc_flutter.dart';

/// Binds an oRPC event iterator to a [ValueListenableBuilder].
class TickerView extends StatefulWidget {
  const TickerView({super.key, required this.controller});

  final RpcSubscriptionController<int> controller;

  @override
  State<TickerView> createState() => _TickerViewState();
}

class _TickerViewState extends State<TickerView> {
  @override
  void initState() {
    super.initState();
    widget.controller.start();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RpcSubscriptionState<int>>(
      valueListenable: widget.controller,
      builder: (context, state, _) =>
          Text('${state.data ?? 0}', textDirection: TextDirection.ltr),
    );
  }
}
