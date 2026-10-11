# SDK پلاگین AyuMC نسخهٔ ۱

پلاگین یک برنامهٔ Dart است که در فرآیند جدا اجرا می‌شود. هسته فهرست رویدادهای بازی را ندارد. قرارداد عمومی نشست در بستهٔ `ayu_session_contracts` است و خود رویداد را پک `session_events` منتشر می‌کند.

## شروع

```dart
import 'package:ayu_plugin_api/ayu_plugin_api.dart';
import 'package:session_audit_plugin/session_audit.dart';

void main() => Ayu.run(SessionAudit.new);
```

`Ayu.run` پلاگین را بعد از رسیدن context سرور می‌سازد. فیلدها را خودتان در سازنده مقدار می‌دهید. فریم‌ورک فیلدی را مخفی پر نمی‌کند و annotation یا build_runner لازم نیست.

هویت بسته، نسخه، API، پروفایل و قراردادهای لازم در `ayu.package.toml` است، نه دوباره داخل کلاس. ابزار ساخت از همان فایل `manifest.json` را می‌سازد.

## شنونده

```dart
final class ConnectionListener extends Listener {
  ConnectionListener({required this.context, required this.config});

  final PluginContext context;
  final AuditConfig config;

  @override
  List<BoundHandler> get handlers => [
    on(SessionEvents.joined, _join),
    on(SessionEvents.left, _leave),
  ];
}
```

`on` نوع payload را با قرارداد یکی می‌کند. اگر تابع را برای قرارداد دیگر بنویسید، تحلیل‌گر خطا می‌دهد. نام قرارداد برای مسیریابی همان `session.joined` است.

نمونهٔ شنونده را در یک فیلد سازنده نگه دارید. getter فقط همان نمونه را برمی‌گرداند. رانر یک بار `listeners` را می‌خواند.

هر رویداد یک snapshot می‌گیرد و هم کلید روشن بودن و هم متن را از همان نسخه می‌خواند:

```dart
void _join(SessionJoined event) {
  final snapshot = config.snapshot;
  if (!snapshot.read(config.logJoins)) return;
  final message = snapshot.render(
    config.joinMessage,
    PlaceholderContext(playerName: event.player.name),
  );
  context.log.info('[SessionAudit] $message');
}
```

رانر موقع روشن شدن این handlerها را subscribe می‌کند و موقع خاموش شدن خودش آن‌ها را لغو می‌کند. لازم نیست برای هر کدام `EventSubscription` نگه دارید.

## بازیکن

`event.player` یک `PlayerRef` است: نام، uuid و entityId که داخل همان بسته آمده‌اند. این شیء بازیکن زندهٔ داخل حافظهٔ سرور نیست و از فرآیند پلاگین به هسته نمی‌رود. فرستادن پیام داخل بازی هنوز ساخته نشده است.

## تنظیمات

همان AyuConfig قبلی است. ذخیرهٔ `config.ayuconf` معتبر، worker را ری‌استارت نمی‌کند. فایل نامعتبر تنظیم قبلی را نگه می‌دارد. جزئیات در `docs/ayu-config.md` است.

## خاموش شدن

سرور اول تحویل رویداد تازه را قطع می‌کند و ثبت‌های سمت خودش را برمی‌دارد، بعد از worker می‌خواهد `onDisable` را در مهلت محدود اجرا کند. در این فاصله لغو اشتراک و لغو دستور مجاز است تا پاک‌سازی خطا ندهد. اشتراک تازه و دستور تازه مجاز نیست. اگر `onDisable` خطا بدهد، بقیهٔ پاک‌سازی ادامه پیدا می‌کند و تایمرها بسته می‌شوند. اگر worker جواب ندهد، سرور بعد از مهلت آن را می‌بندد.

دستورهایی که با `PluginCommand` ثبت شوند دستور کنسول سرور هستند، نه دستور داخل چت ماینکرفت.

اجازهٔ بازیکن (permission) هنوز اعمال نمی‌شود.

## ساخت بسته

در ریشهٔ مخزن:

```text
dart run packages/ayu_tool/bin/ayu.dart plugin package -p examples/session_audit_plugin
```

خروجی `examples/session_audit_plugin/build/ayu/session_audit-1.0.0.ayu` است. نصب از مدیر ترمینال است. حذف نسخهٔ نصب‌شده، سورس و فایل ساخته‌شده را پاک نمی‌کند.
