import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/app_instance_lease.dart';
import 'package:yixue_app/features/brand/startup_error_page.dart';

void main() {
  test(
    'releases a retained lease so startup can retry in this process',
    () async {
      final dataDirectory = await Directory.systemTemp.createTemp(
        'yixue-instance-lease-retry-',
      );
      try {
        final firstLease = await AppInstanceLease.acquire(dataDirectory);
        AppInstanceLease.retainForProcessLifetime(firstLease);

        await AppInstanceLease.releaseProcessLeaseAfterFailedLaunch();

        final retryLease = await AppInstanceLease.acquire(dataDirectory);
        await retryLease.close();
      } finally {
        if (AppInstanceLease.hasProcessLease) {
          await AppInstanceLease.releaseProcessLeaseAfterFailedLaunch();
        }
        await dataDirectory.delete(recursive: true);
      }
    },
  );

  test('recognizes a Windows lock violation as another app instance', () {
    final error = FileSystemException(
      'lock failed',
      r'D:\Yixue\user-data\.yixue-instance.lock',
      OSError('The file is locked by another process.', 33),
    );

    expect(isAppInstanceLeaseContention(error), isTrue);
  });

  test('does not classify other lock failures as instance contention', () {
    final permissionError = FileSystemException(
      'lock failed',
      r'D:\Yixue\user-data\.yixue-instance.lock',
      OSError('Access is denied.', 5),
    );
    final unrelatedFileError = FileSystemException(
      'open failed',
      r'D:\Yixue\user-data\.yixue-instance.lock',
      OSError('The file is locked by another process.', 33),
    );

    expect(isAppInstanceLeaseContention(permissionError), isFalse);
    expect(isAppInstanceLeaseContention(unrelatedFileError), isFalse);
  });

  testWidgets('instance lock page asks to retry without splitting data', (
    tester,
  ) async {
    var retryCount = 0;
    var chooseDataCount = 0;

    await tester.pumpWidget(
      AppStartupErrorPage(
        error: const AppInstanceLeaseConflictException(),
        onRetry: () => retryCount++,
        onChooseData: () => chooseDataCount++,
      ),
    );

    expect(find.text('译学资料库正在使用中'), findsOneWidget);
    expect(find.text('重新检查占用'), findsOneWidget);
    expect(find.textContaining('等几秒再重新检查'), findsOneWidget);
    expect(find.textContaining('结束确认卡住的旧进程'), findsNothing);
    expect(find.text('更换资料库位置'), findsNothing);

    await tester.tap(find.text('重新检查占用'));
    await tester.pump();
    expect(retryCount, 1);
    expect(chooseDataCount, 0);
    expect(tester.takeException(), isNull);
  });
}
