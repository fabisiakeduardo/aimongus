// Ship3D — the whole ship rendered as a WebGL scene instead of DOM/SVG.
//
// LiveView stays the single source of truth: the map arrives once via
// `data-map` (this element is phx-update=ignore, so it never changes),
// and every patch updates `data-state` on the hidden #ship-state
// sibling — a tiny JSON snapshot of pawn positions, bodies and lights.
// A MutationObserver applies each snapshot, and the render loop eases
// pawns toward their authoritative position at display frame rate.
// Result: server-faithful positions, zero DOM churn, butter movement.
import * as THREE from "three"
import {OrbitControls} from "three/addons/controls/OrbitControls.js"

const WALL_H = 0.55
const CORRIDOR = 0x3a4c60
const FLOOR_BASE = 0x9fb4c4

function hsl(h, s = 45, l = 62) {
  return new THREE.Color().setHSL(((h % 360) + 360) % 360 / 360, s / 100, l / 100)
}

function labelSprite(text, color = "#ffffff", size = 44) {
  const pad = 12
  const cv = document.createElement("canvas")
  const ctx = cv.getContext("2d")
  ctx.font = `800 ${size}px "Luckiest Guy", system-ui, sans-serif`
  const w = Math.ceil(ctx.measureText(text).width) + pad * 2
  cv.width = w
  cv.height = size + pad * 2
  const c2 = cv.getContext("2d")
  c2.font = `800 ${size}px "Luckiest Guy", system-ui, sans-serif`
  c2.textBaseline = "middle"
  c2.lineWidth = size / 7
  c2.strokeStyle = "rgba(4,8,14,0.9)"
  c2.strokeText(text, pad, cv.height / 2)
  c2.fillStyle = color
  c2.fillText(text, pad, cv.height / 2)
  const tex = new THREE.CanvasTexture(cv)
  const sp = new THREE.Sprite(new THREE.SpriteMaterial({map: tex, transparent: true}))
  sp.scale.set(w / size * 0.9, (cv.height / size) * 0.9, 1)
  return sp
}

// A bean: capsule body + cyan visor + dark backpack. Very crewmate.
function beanMesh(hex) {
  const g = new THREE.Group()
  const color = new THREE.Color(hex)
  const dark = color.clone().multiplyScalar(0.62)

  const body = new THREE.Mesh(
    new THREE.CapsuleGeometry(0.34, 0.3, 6, 16),
    new THREE.MeshStandardMaterial({color, roughness: 0.55})
  )
  body.position.y = 0.5
  body.name = "body"
  g.add(body)

  const pack = new THREE.Mesh(
    new THREE.BoxGeometry(0.42, 0.5, 0.2),
    new THREE.MeshStandardMaterial({color: dark, roughness: 0.7})
  )
  pack.position.set(0, 0.52, -0.38)
  g.add(pack)

  const visor = new THREE.Mesh(
    new THREE.SphereGeometry(0.21, 16, 12),
    new THREE.MeshStandardMaterial({
      color: 0x9fd8e8, roughness: 0.15, metalness: 0.55,
      emissive: 0x18323d, emissiveIntensity: 0.6,
    })
  )
  visor.scale.set(1.15, 0.62, 0.55)
  visor.position.set(0, 0.66, 0.26)
  g.add(visor)

  return g
}

function propMesh(kind) {
  const mat = new THREE.MeshStandardMaterial({color: 0x4a5a6a, roughness: 0.8})
  const dark = new THREE.MeshStandardMaterial({color: 0x33404e, roughness: 0.85})
  const screen = new THREE.MeshStandardMaterial({
    color: 0x1b2733, emissive: 0x2ee6a8, emissiveIntensity: 0.35, roughness: 0.4,
  })
  const g = new THREE.Group()
  const add = (geo, m, y, s) => {
    const mesh = new THREE.Mesh(geo, m)
    mesh.position.y = y
    if (s) mesh.scale.set(...s)
    g.add(mesh)
    return mesh
  }
  switch (kind) {
    case "table":    add(new THREE.CylinderGeometry(0.42, 0.42, 0.12, 12), mat, 0.42); add(new THREE.CylinderGeometry(0.1, 0.12, 0.42, 8), dark, 0.21); break
    case "admin":    add(new THREE.CylinderGeometry(0.5, 0.5, 0.4, 3), mat, 0.2); add(new THREE.BoxGeometry(0.4, 0.18, 0.3), screen, 0.5); break
    case "console":  add(new THREE.BoxGeometry(0.8, 0.5, 0.45), mat, 0.25); add(new THREE.BoxGeometry(0.6, 0.28, 0.06), screen, 0.55).position.z = 0.1; break
    case "helm":     add(new THREE.CylinderGeometry(0.45, 0.5, 0.5, 8), mat, 0.25); add(new THREE.BoxGeometry(0.7, 0.35, 0.08), screen, 0.62).position.z = 0.05; break
    case "rods":     for (let i = 0; i < 3; i++) add(new THREE.CylinderGeometry(0.07, 0.07, 0.9, 8), screen, 0.45).position.x = (i - 1) * 0.22; break
    case "bed":      add(new THREE.BoxGeometry(0.5, 0.22, 0.9), dark, 0.11); break
    case "crate":    add(new THREE.BoxGeometry(0.6, 0.6, 0.6), mat, 0.3); break
    case "plant":    add(new THREE.ConeGeometry(0.22, 0.5, 8), new THREE.MeshStandardMaterial({color: 0x3f9d5a}), 0.45); add(new THREE.CylinderGeometry(0.12, 0.15, 0.2, 8), dark, 0.1); break
    case "panel":    add(new THREE.BoxGeometry(0.9, 0.9, 0.12), mat, 0.45); break
    case "monitor":  for (let i = 0; i < 2; i++) add(new THREE.BoxGeometry(0.42, 0.3, 0.05), screen, 0.75).position.x = (i - 0.5) * 0.5; add(new THREE.BoxGeometry(1.05, 0.4, 0.3), mat, 0.2); break
    case "engine":   add(new THREE.CylinderGeometry(0.4, 0.45, 0.9, 12), dark, 0.45); add(new THREE.CylinderGeometry(0.3, 0.3, 0.12, 12), screen, 0.96); break
    default:         add(new THREE.BoxGeometry(0.5, 0.5, 0.5), mat, 0.25)
  }
  return g
}

export const Ship3D = {
  mounted() {
    this.map = JSON.parse(this.el.dataset.map)
    this.pawns = new Map()   // id -> {group, target:{x,z}, bob, name}
    this.bodies = new Map()  // key -> mesh
    this.prevFacing = new Map()

    const {w, h} = this.map
    this.scene = new THREE.Scene()
    this.scene.background = new THREE.Color(0x060a12)

    this.ambient = new THREE.AmbientLight(0xffffff, 1.05)
    this.scene.add(this.ambient)
    const dir = new THREE.DirectionalLight(0xffffff, 1.7)
    dir.position.set(w * 0.3, 30, h * 0.2)
    this.scene.add(dir)

    const aspect = () => this.el.clientWidth / Math.max(1, this.el.clientHeight)
    const d = Math.max(w, h) * 0.62
    this.camera = new THREE.OrthographicCamera(-d, d, d, -d, 0.1, 200)
    this.camera.position.set(w / 2, 60, h / 2 + 0.01)
    this.camera.up.set(0, 0, -1)
    this.camera.lookAt(w / 2, 0, h / 2)

    this.renderer = new THREE.WebGLRenderer({antialias: true})
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
    this.el.appendChild(this.renderer.domElement)

    this.controls = new OrbitControls(this.camera, this.renderer.domElement)
    this.controls.target.set(w / 2, 0, h / 2)
    this.controls.enableRotate = false
    this.controls.mouseButtons = {LEFT: THREE.MOUSE.PAN, MIDDLE: THREE.MOUSE.PAN, RIGHT: THREE.MOUSE.PAN}
    this.controls.minZoom = 0.7
    this.controls.maxZoom = 6

    this.buildMap()
    this.raycaster = new THREE.Raycaster()
    this.pointer = new THREE.Vector2()
    this.renderer.domElement.addEventListener("click", e => this.onClick(e))

    this.stateEl = document.getElementById("ship-state")
    this.applyState()
    this.observer = new MutationObserver(() => this.applyState())
    this.observer.observe(this.stateEl, {attributes: true, attributeFilter: ["data-state"]})

    this.resize = () => {
      const cw = this.el.clientWidth, ch = this.el.clientHeight
      this.renderer.setSize(cw, ch)
      const a = aspect()
      const base = Math.max(this.map.w, this.map.h * a) * 0.6
      this.camera.left = -base; this.camera.right = base
      this.camera.top = base / a; this.camera.bottom = -base / a
      this.camera.updateProjectionMatrix()
    }
    this.resizeObs = new ResizeObserver(this.resize)
    this.resizeObs.observe(this.el)
    this.resize()

    this.clock = new THREE.Clock()
    this.renderer.setAnimationLoop(() => this.frame())
  },

  destroyed() {
    this.observer?.disconnect()
    this.resizeObs?.disconnect()
    this.renderer?.setAnimationLoop(null)
    this.renderer?.dispose()
  },

  buildMap() {
    const {rows, rooms, props, tasks, button, w, h} = this.map

    // floors — one instanced quad per walkable cell, tinted per room
    const cells = []
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      if (rows[y][x] !== -1) cells.push([x, y, rows[y][x]])
    }
    const floorGeo = new THREE.PlaneGeometry(1, 1)
    const floors = new THREE.InstancedMesh(floorGeo,
      new THREE.MeshStandardMaterial({color: 0xffffff, roughness: 0.9}), cells.length)
    const m4 = new THREE.Matrix4()
    const q = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), -Math.PI / 2)
    cells.forEach(([x, y, r], i) => {
      m4.makeRotationFromQuaternion(q).setPosition(x + 0.5, 0, y + 0.5)
      floors.setMatrixAt(i, m4)
      floors.setColorAt(i, r >= 0 ? hsl(rooms[r].h, 42, 64) : new THREE.Color(CORRIDOR))
    })
    this.scene.add(floors)

    // walls — instanced extruded boxes
    const walls = []
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      if (rows[y][x] === -1) walls.push([x, y])
    }
    const wallMesh = new THREE.InstancedMesh(new THREE.BoxGeometry(1, WALL_H, 1),
      new THREE.MeshStandardMaterial({color: 0x1c2836, roughness: 0.85}), walls.length)
    walls.forEach(([x, y], i) => {
      m4.makeTranslation(x + 0.5, WALL_H / 2, y + 0.5)
      wallMesh.setMatrixAt(i, m4)
    })
    this.scene.add(wallMesh)

    // room labels
    const centers = rooms.map(() => [0, 0, 0])
    cells.forEach(([x, y, r]) => {
      if (r >= 0) { centers[r][0] += x + 0.5; centers[r][1] += y + 0.5; centers[r][2]++ }
    })
    rooms.forEach((room, i) => {
      const [sx, sy, n] = centers[i]
      if (!n) return
      const sp = labelSprite(room.n.toUpperCase(), "#cfe3f0", 30)
      sp.position.set(sx / n, 0.15, sy / n)
      sp.material.opacity = 0.55
      this.scene.add(sp)
    })

    // props
    for (const p of props) {
      const mesh = propMesh(p.k)
      mesh.position.set(p.x + 0.5, 0, p.y + 0.5)
      this.scene.add(mesh)
    }

    // task markers — small glowing pads
    for (const [, [x, y]] of Object.entries(tasks)) {
      const t = new THREE.Mesh(new THREE.CylinderGeometry(0.16, 0.16, 0.06, 10),
        new THREE.MeshStandardMaterial({color: 0xd8b93a, emissive: 0x8a6d12, emissiveIntensity: 0.5}))
      t.position.set(x + 0.5, 0.03, y + 0.5)
      this.scene.add(t)
    }
    if (button) {
      const b = new THREE.Mesh(new THREE.CylinderGeometry(0.28, 0.32, 0.12, 16),
        new THREE.MeshStandardMaterial({color: 0xc22e2e, emissive: 0x5a0e0e, emissiveIntensity: 0.6}))
      b.position.set(button[0] + 0.5, 0.06, button[1] + 0.5)
      this.scene.add(b)
    }
  },

  applyState() {
    if (!this.stateEl?.dataset.state) return
    const st = JSON.parse(this.stateEl.dataset.state)
    const cell = this.map.cell

    for (const [id, p] of Object.entries(st.players)) {
      let pawn = this.pawns.get(id)
      if (!pawn) {
        const group = beanMesh(p.c)
        const name = labelSprite(p.n || id, p.c, 34)
        name.position.y = 1.45
        group.add(name)
        const sel = new THREE.Mesh(new THREE.RingGeometry(0.42, 0.52, 24),
          new THREE.MeshBasicMaterial({color: 0xe8f4ff, transparent: true, opacity: 0.9}))
        sel.rotation.x = -Math.PI / 2
        sel.position.y = 0.03
        sel.name = "sel"
        sel.visible = false
        group.add(sel)
        group.userData.id = id
        const px = p.p[0] * cell + p.o[0], pz = p.p[1] * cell + p.o[1]
        group.position.set(px / cell, 0, pz / cell)
        this.scene.add(group)
        pawn = {group, target: new THREE.Vector3(px / cell, 0, pz / cell), ejected: false}
        this.pawns.set(id, pawn)
      }
      const tx = (p.p[0] * cell + p.o[0]) / cell
      const tz = (p.p[1] * cell + p.o[1]) / cell
      pawn.target.set(tx, 0, tz)
      pawn.moving = p.m
      pawn.group.userData.pick = id
      // alive → solid; ghost → translucent; ejected → launches and despawns
      const body = pawn.group.getObjectByName("body")
      body.material.transparent = !p.a
      body.material.opacity = p.a ? 1 : 0.3
      pawn.group.getObjectByName("sel").visible = !!p.sel
      if (p.e && !pawn.ejected) pawn.ejected = 0.001
    }

    // bodies
    const seen = new Set()
    st.bodies.forEach((b, i) => {
      const key = `${b.p[0]},${b.p[1]}`
      seen.add(key)
      if (!this.bodies.has(key)) {
        const corpse = beanMesh(b.c)
        corpse.rotation.z = Math.PI / 2
        corpse.position.set(b.p[0] + 0.3, 0.32, b.p[1] + 0.5)
        this.scene.add(corpse)
        this.bodies.set(key, corpse)
      }
    })
    for (const [key, mesh] of this.bodies) {
      if (!seen.has(key)) { this.scene.remove(mesh); this.bodies.delete(key) }
    }

    this.ambient.intensity = st.lights ? 0.15 : 1.05
  },

  onClick(e) {
    const rect = this.renderer.domElement.getBoundingClientRect()
    this.pointer.set(
      ((e.clientX - rect.left) / rect.width) * 2 - 1,
      -((e.clientY - rect.top) / rect.height) * 2 + 1
    )
    this.raycaster.setFromCamera(this.pointer, this.camera)
    const hits = this.raycaster.intersectObjects(
      [...this.pawns.values()].map(p => p.group), true)
    const hit = hits.find(h => h.object.parent?.userData.pick || h.object.userData.pick)
    if (hit) {
      const id = hit.object.userData.pick || hit.object.parent.userData.pick
      this.pushEvent("select_agent", {id})
    }
  },

  frame() {
    const t = this.clock.getElapsedTime()
    for (const [id, pawn] of this.pawns) {
      const g = pawn.group
      if (pawn.ejected) {
        pawn.ejected += 0.016
        g.position.y += pawn.ejected * 0.12
        g.rotation.y += 0.12
        if (g.position.y > 14) { this.scene.remove(g); this.pawns.delete(id) }
        continue
      }
      const dx = pawn.target.x - g.position.x
      const dz = pawn.target.z - g.position.z
      const dist = Math.hypot(dx, dz)
      if (dist > 6) { g.position.copy(pawn.target) }        // teleports: snap
      else if (dist > 0.01) {                               // walk: glide
        g.position.x += dx * 0.22
        g.position.z += dz * 0.22
      }
      // face travel direction + waddle bob while moving
      const face = this.prevFacing.get(id) || 0
      if (dist > 0.05) {
        const want = Math.atan2(dx, dz)
        g.rotation.y = face + (((want - face + Math.PI * 3) % (Math.PI * 2)) - Math.PI) * 0.2
        this.prevFacing.set(id, g.rotation.y)
        g.position.y = Math.abs(Math.sin(t * 11)) * 0.07
        g.rotation.z = Math.sin(t * 11) * 0.05
      } else {
        g.position.y *= 0.8
        g.rotation.z *= 0.8
      }
    }
    this.controls.update()
    this.renderer.render(this.scene, this.camera)
  },
}
