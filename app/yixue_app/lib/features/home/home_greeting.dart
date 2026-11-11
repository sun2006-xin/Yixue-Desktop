import 'package:yixue_app/core/home_workbench.dart';

String homeGreeting(
  DateTime now, {
  HomeUserProfileData? profile,
  int focusMinutes = 0,
}) {
  final name = profile?.displayName.trim() ?? '';
  final suffix = name.isEmpty ? '' : '，$name';
  final greeting = now.hour == 0 && now.minute == 0 && now.second == 0
      ? '上午好'
      : now.hour < 5
      ? '夜深了'
      : now.hour < 12
      ? '上午好'
      : now.hour < 18
      ? '下午好'
      : '晚上好';
  if (focusMinutes >= 90) return '休息一会儿吧$suffix';
  return '$greeting$suffix，今天从一件重要的事开始';
}

String homeEncouragement(HomeUserProfileData? profile) {
  final custom = profile?.encouragement.trim() ?? '';
  return custom.isEmpty ? '译懂世界，学会表达。' : custom;
}
