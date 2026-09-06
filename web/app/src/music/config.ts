import {
  AURORA_PALETTE,
  CLUB_PALETTE,
  clamp01,
  FLASH_HARD_CEILING,
  OCEAN_PALETTE,
  SOUNDCHECK_PALETTE,
  SUNSET_PALETTE,
  type FixtureRole,
  type MusicModeConfiguration,
  type MusicModePreset,
} from "./types";

export const PRESET_COPY: Record<
  Exclude<MusicModePreset, "custom">,
  { name: string; summary: string; plain: string; bestFor: string }
> = {
  ambient: {
    name: "Ambient",
    summary: "Slow colour, restrained brightness, no flashes.",
    plain: "Quiet background glow. Colours drift slowly and nothing jumps out at you.",
    bestFor: "Dinner and background music",
  },
  balanced: {
    name: "Balanced",
    summary: "Beat pulses, frequency colour, moderate movement.",
    plain: "The everyday setting. Lights pulse with the beat, change colour as the music changes, and move a little.",
    bestFor: "Anything, if you are unsure",
  },
  concert: {
    name: "Concert",
    summary: "Percussion accents and faster traveling motion.",
    plain: "Loud and punchy. Drums land hard and colour travels across the room quickly.",
    bestFor: "Rock, pop, parties",
  },
  cinematic: {
    name: "Cinematic",
    summary: "Broad sweeps, gradual energy, infrequent bursts.",
    plain: "Slow, wide swells that build and release.",
    bestFor: "Scores and ambient",
  },
  soundcheck: {
    name: "Soundcheck",
    summary: "The original beat-and-instrument response, made safer.",
    plain: "The look LumenDesk shipped with before Music Mode, without the harsh flashing.",
    bestFor: "The old LumenDesk look",
  },
  club: {
    name: "Club",
    summary: "Four-on-the-floor wash plus a hard hit layer on the downbeat.",
    plain: "Steady pulse on every beat with a hard punch on the first beat of each bar.",
    bestFor: "House, techno, dance",
  },
  halftime: {
    name: "Half-time",
    summary: "Felt pulse on every other beat. Head-nod, not strobe.",
    plain: "Pulses on every other beat, so the room nods along instead of strobing.",
    bestFor: "Hip-hop and slow, heavy music",
  },
  waltz: {
    name: "Waltz",
    summary: "Three-count swell. Downbeat takes the room, two and three breathe.",
    plain: "Counts in threes. The first beat takes the room, the next two breathe.",
    bestFor: "Music that counts in threes",
  },
};

/**
 * Plain-language copy for the browser client, kept in step with the native
 * app's `MusicModeHelp` so both clients explain the same feature the same way.
 * Wording may differ where the platforms differ; meaning may not.
 */
export const ROLE_COPY: Record<FixtureRole, { name: string; plain: string }> = {
  auto: {
    name: "Auto",
    plain: 'Let LumenDesk choose from the light\'s name: one with "kick" or "downstage" takes the punch, one with "rear" or "accent" takes the second colour, and the rest fill the room. The bridge does not report segments, so nothing gets the travelling colour on its own here. Pick Motion by hand for a strip.',
  },
  wash: { name: "Wash", plain: "Fills the room. Bright and steady with a soft pulse underneath." },
  hit: { name: "Hit", plain: "Punches on the beat. Give this to the light you want the kick drum to land in." },
  accent: { name: "Accent", plain: "Answers the snare and cymbals in a second colour. Best off to one side." },
  motion: { name: "Motion", plain: "Colour runs across it in time with the music. Best on a strip." },
  off: { name: "Off", plain: "Sits this one out and keeps whatever it is showing right now." },
};

export const SOURCE_COPY: Record<string, { name: string; plain: string }> = {
  microphone: {
    name: "Microphone",
    plain: "Starts the show listening to the room, so the music has to be audible. The browser asks for microphone access the first time.",
  },
  file: {
    name: "Audio file",
    plain: "Pick a song from this computer and the show starts on it. The page plays the track and lights to it, which is the most reliable option.",
  },
  midi: {
    name: "MIDI clock",
    plain: "Starts the show on a beat sent by DJ software, a drum machine, or recording software over MIDI.",
  },
  demo: {
    name: "Demo groove",
    plain: "Starts the show on a built-in rhythm with no audio at all. Use it to see what the lights do before you commit to a track.",
  },
};

export const MUSIC_HELP = {
  steps: [
    "Pick a preset from the panel below. Balanced is the safe first choice, and you can change it while the show runs.",
    "Choose where the sound comes from. Each source button starts the show as soon as you pick it, and the microphone or a file may ask for permission first. Start then restarts whatever source you last chose.",
    "Stop ends the show. The lights hold the last colour they were sent, so apply a scene from Library if you want them back where they were.",
  ],
  readout:
    'The bars show what the page is hearing: overall volume, then bass, mids and highs. The dot flashes on each beat. Once the tempo locks — usually about four seconds of steady rhythm — the label changes from "Beat" to the speed in beats per minute and how many beats are in a bar.',
  roles:
    "Every light gets a job. Auto picks one for you and is fine for most rooms; change one only if you want that specific light doing something else.",
  safety:
    "Flashing is blocked by default, because flashing light can trigger seizures and migraines in some people. Nothing here can exceed three flashes a second.",
  strips:
    "Strip lights follow as a single colour in the browser. Per-segment chases stay in the Mac and iPhone apps for now.",
} as const;

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
