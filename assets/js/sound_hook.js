// SoundHook — synthesized spectator audio for SpectateLive.
//
// The LiveView pushes `push_event("sound", %{name: ...})`; this hook maps
// each name to a short WebAudio cue. Every sound is generated on the fly
// from oscillators and filtered noise — there are no audio files, so
// there is nothing to download, license, or attribute.
//
// Sound names pushed by the server:
//   "ambient"  — start the ship hum loop (runs until stopped)
//   "kill"     — kill stinger
//   "report"   — body-found / emergency-button alert
//   "siren"    — meeting siren
//   "vote"     — vote-cast blip
//   "eject"    — airlock woosh
//   "win"      — crew victory sting (also stops the hum)
//   "lose"     — impostor/solo victory sting (also stops the hum)
//   "control"  — %{muted, ambient} sync sent by the mute toggle
//
// Autoplay policy: browsers block audio before the first user gesture.
// The page therefore mounts muted; clicking the "Enable sound" button is
// itself the gesture that unlocks audio. The hook also resumes its
// AudioContext on the first pointerdown/keydown anywhere on the page,
// so an already-unmuted viewer hears everything after they interact.
export const SoundHook = {
  mounted() {
    this.ctx = null
    this.master = null
    this.muted = true
    this.ambientNodes = null
    this.noiseBuf = null

    this.handleEvent("sound", (payload) => this.onSound(payload))

    const unlock = () => this.ensureCtx()
    this.el.addEventListener("pointerdown", unlock)
    this.el.addEventListener("keydown", unlock)
  },

  destroyed() {
    this.stopAmbient()
    if (this.ctx) this.ctx.close().catch(() => {})
    this.ctx = null
    this.master = null
  },

  onSound({name, muted, ambient}) {
    if (name === "control") {
      this.muted = muted
      if (muted) this.stopAmbient()
      else if (ambient) this.startAmbient()
      return
    }

    if (this.muted || !this.ensureCtx()) return

    switch (name) {
      case "ambient":
        this.startAmbient()
        break
      case "kill":
        this.kill()
        break
      case "report":
        this.report()
        break
      case "siren":
        this.siren()
        break
      case "vote":
        this.vote()
        break
      case "eject":
        this.eject()
        break
      case "win":
        this.stopAmbient()
        this.win()
        break
      case "lose":
        this.stopAmbient()
        this.lose()
        break
    }
  },

  // Lazily create the AudioContext and poke it awake; returns null when
  // WebAudio is unavailable. Scheduling on a still-suspended context is
  // harmless — queued cues play once the first gesture resumes it.
  ensureCtx() {
    if (!this.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext
      if (!AC) return null
      this.ctx = new AC()
      this.master = this.ctx.createGain()
      this.master.gain.value = 0.8
      this.master.connect(this.ctx.destination)
    }
    if (this.ctx.state === "suspended") this.ctx.resume().catch(() => {})
    return this.ctx
  },

  // One oscillator with an attack/decay envelope and an optional pitch
  // sweep. `t` is a delay in seconds from now.
  tone({type = "sine", freq = 440, to = null, t = 0, dur = 0.2, gain = 0.2, attack = 0.005}) {
    const ctx = this.ctx
    const t0 = ctx.currentTime + t
    const osc = ctx.createOscillator()
    const g = ctx.createGain()

    osc.type = type
    osc.frequency.setValueAtTime(freq, t0)
    if (to) osc.frequency.exponentialRampToValueAtTime(Math.max(to, 1), t0 + dur)

    g.gain.setValueAtTime(0, t0)
    g.gain.linearRampToValueAtTime(gain, t0 + attack)
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur)

    osc.connect(g).connect(this.master)
    osc.start(t0)
    osc.stop(t0 + dur + 0.05)
  },

  // Shared 1s white-noise buffer, reused by every noise-based cue.
  noiseBuffer() {
    if (!this.noiseBuf) {
      const ctx = this.ctx
      const buf = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate)
      const data = buf.getChannelData(0)
      for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1
      this.noiseBuf = buf
    }
    return this.noiseBuf
  },

  // Filtered noise burst with an optional filter-frequency sweep.
  noise({dur = 0.5, gain = 0.2, filter = "bandpass", freq = 1000, to = null, q = 1, t = 0}) {
    const ctx = this.ctx
    const t0 = ctx.currentTime + t
    const src = ctx.createBufferSource()
    const f = ctx.createBiquadFilter()
    const g = ctx.createGain()

    src.buffer = this.noiseBuffer()
    src.loop = true

    f.type = filter
    f.frequency.setValueAtTime(freq, t0)
    f.Q.value = q
    if (to) f.frequency.exponentialRampToValueAtTime(Math.max(to, 20), t0 + dur)

    g.gain.setValueAtTime(0, t0)
    g.gain.linearRampToValueAtTime(gain, t0 + 0.02)
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur)

    src.connect(f).connect(g).connect(this.master)
    src.start(t0)
    src.stop(t0 + dur + 0.05)
  },

  // The ship hum: two slightly detuned low oscillators beating against
  // each other plus low-passed noise, swelling slowly via an LFO.
  startAmbient() {
    if (this.muted || this.ambientNodes || !this.ensureCtx()) return
    const ctx = this.ctx
    const t0 = ctx.currentTime

    const g = ctx.createGain()
    g.gain.setValueAtTime(0, t0)
    g.gain.linearRampToValueAtTime(0.055, t0 + 2)

    const lfo = ctx.createOscillator()
    lfo.frequency.value = 0.08
    const lfoGain = ctx.createGain()
    lfoGain.gain.value = 0.02
    lfo.connect(lfoGain).connect(g.gain)

    const hum1 = ctx.createOscillator()
    hum1.type = "sine"
    hum1.frequency.value = 55
    const hum2 = ctx.createOscillator()
    hum2.type = "triangle"
    hum2.frequency.value = 55.4
    const hum2Gain = ctx.createGain()
    hum2Gain.gain.value = 0.5

    const hiss = ctx.createBufferSource()
    hiss.buffer = this.noiseBuffer()
    hiss.loop = true
    const lp = ctx.createBiquadFilter()
    lp.type = "lowpass"
    lp.frequency.value = 240
    const hissGain = ctx.createGain()
    hissGain.gain.value = 0.35

    hum1.connect(g)
    hum2.connect(hum2Gain).connect(g)
    hiss.connect(lp).connect(hissGain).connect(g)
    g.connect(this.master)

    for (const node of [hum1, hum2, hiss, lfo]) node.start()
    this.ambientNodes = {g, lfo, sources: [hum1, hum2, hiss]}
  },

  stopAmbient() {
    const nodes = this.ambientNodes
    if (!nodes || !this.ctx) return
    this.ambientNodes = null

    const t0 = this.ctx.currentTime
    nodes.g.gain.cancelScheduledValues(t0)
    nodes.g.gain.setTargetAtTime(0, t0, 0.25)
    for (const src of [...nodes.sources, nodes.lfo]) {
      try {
        src.stop(t0 + 1.5)
      } catch (_e) {
        // already stopped
      }
    }
  },

  // Kill stinger: noise snap + falling saw + sub thump.
  kill() {
    this.noise({dur: 0.22, freq: 3200, to: 300, gain: 0.4})
    this.tone({type: "sawtooth", freq: 720, to: 85, dur: 0.45, gain: 0.22})
    this.tone({freq: 130, to: 42, dur: 0.4, gain: 0.4})
  },

  // Body report / emergency button: three rising alert blips.
  report() {
    this.tone({type: "square", freq: 523, dur: 0.11, gain: 0.12})
    this.tone({type: "square", freq: 659, dur: 0.11, gain: 0.12, t: 0.13})
    this.tone({type: "square", freq: 880, dur: 0.2, gain: 0.12, t: 0.26})
  },

  // Meeting siren: two alternating triangle tones, four cycles.
  siren() {
    for (let i = 0; i < 4; i++) {
      this.tone({type: "triangle", freq: 660, dur: 0.18, gain: 0.2, t: i * 0.4})
      this.tone({type: "triangle", freq: 880, dur: 0.18, gain: 0.2, t: i * 0.4 + 0.2})
    }
  },

  // Vote cast: a quick two-note UI blip.
  vote() {
    this.tone({type: "square", freq: 1150, dur: 0.06, gain: 0.1})
    this.tone({type: "square", freq: 1550, dur: 0.08, gain: 0.1, t: 0.07})
  },

  // Ejection: an airlock woosh plus a long falling whistle.
  eject() {
    this.noise({dur: 1.1, freq: 1900, to: 160, gain: 0.32, q: 0.7})
    this.tone({freq: 420, to: 55, dur: 1.0, gain: 0.14})
  },

  // Crew victory: rising major arpeggio.
  win() {
    const notes = [523.25, 659.25, 783.99, 1046.5]
    notes.forEach((freq, i) =>
      this.tone({type: "triangle", freq, dur: i === notes.length - 1 ? 0.5 : 0.14, gain: 0.2, t: i * 0.13})
    )
  },

  // Impostor / solo victory: slow minor descent.
  lose() {
    const notes = [440, 349.23, 293.66, 220]
    notes.forEach((freq, i) =>
      this.tone({type: "sawtooth", freq, dur: i === notes.length - 1 ? 0.7 : 0.3, gain: 0.11, t: i * 0.3})
    )
  },
}
