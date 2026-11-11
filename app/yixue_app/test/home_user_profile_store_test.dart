import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/home_user_profile_store.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/features/home/home_greeting.dart';

void main() {
  test('profile persists locally and greeting uses the safe custom fields', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-profile-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileHomeUserProfileStore(
      File('${directory.path}${Platform.pathSeparator}profile.json'),
    );
    final profile = HomeUserProfileData(
      displayName: '花鱼鱼',
      encouragement: '慢慢来，今天也会有收获',
      updatedAt: '2026-09-16T09:00:00+08:00',
    );

    await store.write(profile);
    expect(await store.read(), profile);
    expect(
      homeGreeting(DateTime(2026, 9, 16, 9), profile: profile),
      '上午好，花鱼鱼，今天从一件重要的事开始',
    );
    expect(homeEncouragement(profile), '慢慢来，今天也会有收获');
  });

  test('long focus time changes the greeting into a rest reminder', () {
    const profile = HomeUserProfileData(
      displayName: '花鱼鱼',
      encouragement: '',
      updatedAt: '2026-09-16T09:00:00+08:00',
    );
    expect(
      homeGreeting(DateTime(2026, 9, 16, 15), profile: profile, focusMinutes: 95),
      '休息一会儿吧，花鱼鱼',
    );
  });
}
