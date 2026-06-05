class AppSettings {
  int intervalSec;
  int maxFrames;
  int subsetSize;
  int stepSize;
  int searchRange;
  double znccThreshold;
  double? colorMin; // null = 自動
  double? colorMax;
  String resolution; // '1080p' | '4K' | '最大'

  AppSettings({
    this.intervalSec = 5,
    this.maxFrames = 5,
    this.subsetSize = 31,
    this.stepSize = 15,
    this.searchRange = 20,
    this.znccThreshold = 0.3,
    this.colorMin,
    this.colorMax,
    this.resolution = '1080p',
  });
}
