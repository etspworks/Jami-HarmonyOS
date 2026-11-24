/*
 * Ported from Ring/Ring/Constants/Durations.swift (GPL-3.0, Savoir-faire Linux Inc.).
 * Swift exposed the same value three ways (seconds, milliseconds, RxTimeInterval); every
 * HarmonyOS consumer - animateTo, setTimeout, a throttle - takes milliseconds, so that is
 * the only form kept.
 */
export enum Durations {
  /** 0.2s - switch/toggle throttling. */
  SWITCH_THROTTLING_DURATION = 200,
  /** 0.5s - text-field throttling. */
  TEXT_FIELD_THROTTLING_DURATION = 500,
  HALF_SECOND = 500,
  /** 1s - alert flash. */
  ALERT_FLASH_DURATION = 1000,
  ONE_SECOND = 1000,
  THREE_SECONDS = 3000,
  TEN_SECONDS = 10000,
  SIXTY_SECONDS = 60000
}

/** The Swift `value` accessor - the same duration in seconds. */
export function durationSeconds(duration: Durations): number {
  return duration / 1000;
}
