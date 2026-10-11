import 'package:ayu_plugin_api/ayu_plugin_api.dart';
import 'package:test/test.dart';

void main() {
  test('a typed binding decodes the payload before calling the handler', () {
    final contract = EventContract<_Ping>(
      id: 'test.ping',
      version: '1.0.0',
      decode: (data) => _Ping('${data['name']}'),
    );
    String? seen;
    final binding = on(contract, (_Ping event) => seen = event.name);
    binding.dispatch({'name': 'Ada'});
    expect(binding.contractId, 'test.ping');
    expect(seen, 'Ada');
  });
}

final class _Ping {
  _Ping(this.name);
  final String name;
}
