import {
  AURORA_PALETTE,
  CLUB_PALETTE,
  clamp01,
  FLASH_HARD_CEILING,
  OCEAN_PALETTE,
  SOUNDCHECK_PALETTE,
  SUNSET_PALETTE,
  type MusicModeConfiguration,
  type MusicModePreset,
} from "./types";

export const PRESET_COPY: Record<Exclude<MusicModePreset, "custom">, { name: string; summary: string }> = {
  ambient: { name: "Ambient", summary: "Slow colour, restrained brightness, no flashes." },
  balanced: { name: "Balanced", summary: "Beat pulses, frequency colour, moderate movement." },
  concert: { name: "Concert", summary: "Percussion accents and faster traveling motion." },
  cinematic: { name: "Cinematic", summary: "Broad sweeps, gradual energy, infrequent bursts." },
  soundcheck: { name: "Soundcheck", summary: "The original beat-and-instrument response, made safer." },
  club: { name: "Club", summary: "Four-on-the-floor wash plus a hard hit layer on the downbeat." },
  halftime: { name: "Half-time", summary: "Felt pulse on every other beat. Head-nod, not strobe." },
  waltz: { name: "Waltz", summary: "Three-count swell. Downbeat takes the room, two and three breathe." },
};

export function defaultConfiguration(): MusicModeConfiguration {
  return configurationFor("soundcheck");
}

export function configurationFor(preset: MusicModePreset): MusicModeConfiguration {
  const value: MusicModeConfiguration = {
    preset,
    masterBrightness: 0.82,
    effectIntensity: 0.72,
    beatSensitivity: 0.72,
    bassSensitivity: 0.76,
    percussionSensitivity: 0.68,
    colorChangeIntensity: 0.66,
    movementAmount: 0.58,
    movementDirection: "forward",
    movementSpeed: 0.55,
    minimumBrightness: 0.08,
    maximumBrightness: 0.92,
    allowsFlashes: true,
    flashIntensity: 0.42,
    maximumFlashFrequency: 1.5,
    palette: SOUNDCHECK_PALETTE,
    silenceBehavior: "settle",
    photosensitivitySafeMode: true,
    restorePreviousState: true,
    metreOverride: "auto",
    timeFeel: "auto",
    stereoImage: 0.7,
    phraseAware: true,
  };

  switch (preset) {
    case "ambient":
      Object.assign(value, {
        masterBrightness: 0.55,
        effectIntensity: 0.32,
        beatSensitivity: 0.28,
        bassSensitivity: 0.42,
        percussionSensitivity: 0.18,
        colorChangeIntensity: 0.34,
        movementAmount: 0.32,
        movementSpeed: 0.2,
        minimumBrightness: 0.12,
        maximumBrightness: 0.62,
        allowsFlashes: false,
        flashIntensity: 0,
        maximumFlashFrequency: 0,
        palette: AURORA_PALETTE,
        silenceBehavior: "holdPalette",
      });
      break;
    case "balanced":
      Object.assign(value, {
        masterBrightness: 0.75,
        effectIntensity: 0.62,
        beatSensitivity: 0.68,
        bassSensitivity: 0.7,
        percussionSensitivity: 0.55,
        colorChangeIntensity: 0.58,
        movementAmount: 0.5,
        movementSpeed: 0.48,
        minimumBrightness: 0.1,
        maximumBrightness: 0.84,
        allowsFlashes: false,
        flashIntensity: 0,
        maximumFlashFrequency: 0,
        palette: AURORA_PALETTE,
      });
      break;
    case "concert":
      Object.assign(value, {
        masterBrightness: 0.9,
        effectIntensity: 0.88,
        beatSensitivity: 0.84,
        bassSensitivity: 0.9,
        percussionSensitivity: 0.86,
        colorChangeIntensity: 0.82,
        movementAmount: 0.86,
        movementSpeed: 0.86,
        minimumBrightness: 0.06,
        maximumBrightness: 1,
        allowsFlashes: true,
        flashIntensity: 0.58,
        maximumFlashFrequency: 2,
      });
      break;
    case "cinematic":
      Object.assign(value, {
        masterBrightness: 0.78,
        effectIntensity: 0.7,
        beatSensitivity: 0.48,
        bassSensitivity: 0.68,
        percussionSensitivity: 0.38,
        colorChangeIntensity: 0.54,
        movementAmount: 0.74,
        movementSpeed: 0.28,
        minimumBrightness: 0.08,
        maximumBrightness: 0.9,
        allowsFlashes: true,
        flashIntensity: 0.34,
        maximumFlashFrequency: 0.75,
        palette: SUNSET_PALETTE,
        silenceBehavior: "holdPalette",
      });
      break;
    case "club":
      Object.assign(value, {
        masterBrightness: 0.88,
        effectIntensity: 0.8,
        beatSensitivity: 0.9,
        bassSensitivity: 0.86,
        percussionSensitivity: 0.7,
        colorChangeIntensity: 0.48,
        movementAmount: 0.7,
        movementSpeed: 0.64,
        metreOverride: 4,
        timeFeel: "straight",
        palette: CLUB_PALETTE,
      });
      break;
    case "halftime":
      Object.assign(value, {
        masterBrightness: 0.78,
        effectIntensity: 0.7,
        beatSensitivity: 0.8,
        bassSensitivity: 0.84,
        percussionSensitivity: 0.5,
        colorChangeIntensity: 0.4,
        movementAmount: 0.42,
        movementSpeed: 0.28,
        timeFeel: "half",
        palette: SUNSET_PALETTE,
      });
      break;
    case "waltz":
      Object.assign(value, {
        masterBrightness: 0.7,
        effectIntensity: 0.58,
        beatSensitivity: 0.62,
        bassSensitivity: 0.55,
        percussionSensitivity: 0.32,
        colorChangeIntensity: 0.5,
        movementAmount: 0.48,
        movementSpeed: 0.3,
        metreOverride: 3,
        timeFeel: "straight",
        palette: OCEAN_PALETTE,
        silenceBehavior: "holdPalette",
      });
      break;
    case "custom":
      return { ...configurationFor("balanced"), preset: "custom" };
    case "soundcheck":
      break;
  }
  return normalizeConfiguration(value);
}

export function normalizeConfiguration(
  config: MusicModeConfiguration,
  reducedMotion = false,
): MusicModeConfiguration {
  const value = { ...config, palette: [...config.palette] };
  value.masterBrightness = clamp01(value.masterBrightness);
  value.effectIntensity = clamp01(value.effectIntensity);
  value.beatSensitivity = clamp01(value.beatSensitivity);
  value.bassSensitivity = clamp01(value.bassSensitivity);
  value.percussionSensitivity = clamp01(value.percussionSensitivity);
  value.colorChangeIntensity = clamp01(value.colorChangeIntensity);
  value.movementAmount = clamp01(value.movementAmount);
  value.movementSpeed = clamp01(value.movementSpeed);
  value.minimumBrightness = clamp01(value.minimumBrightness);
  value.maximumBrightness = Math.max(value.minimumBrightness, clamp01(value.maximumBrightness));
  value.flashIntensity = clamp01(value.flashIntensity);
  value.maximumFlashFrequency = Math.max(0, Math.min(FLASH_HARD_CEILING, value.maximumFlashFrequency));
  value.stereoImage = clamp01(value.stereoImage);
  if (value.palette.length === 0) value.palette = SOUNDCHECK_PALETTE;
  if (reducedMotion) {
    value.movementAmount = Math.min(value.movementAmount, 0.18);
    value.movementSpeed = Math.min(value.movementSpeed, 0.22);
    value.flashIntensity = 0;
    value.maximumFlashFrequency = 0;
  }
  return value;
}
