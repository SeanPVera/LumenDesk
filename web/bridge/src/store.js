import fs from 'node:fs'
import fsp from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'

// Rooms, scenes, schedules and device naming live in the bridge rather than the
// browser: they must survive a reload, be shared by every browser on the
// machine, and — for schedules — keep working with no page open at all.
// Mirrors the native app's Room / LightingScene / ScheduleEntry models.

const DEFAULT_FILE = path.join(os.homedir(), '.lumendesk', 'bridge-state.json')

const EMPTY = {
  schemaVersion: 1,
  rooms: [],
  scenes: [],
  favorites: [],
  deviceNames: {},
}

export const id = () => crypto.randomUUID()

export class Store {
  constructor({ file = DEFAULT_FILE, log = () => {} } = {}) {
    this.file = file
    this.log = log
    this.state = { ...EMPTY }
    this.writing = null
    this.pending = false
    this.lastWriteError = null
  }

  load() {
    try {
      const raw = fs.readFileSync(this.file, 'utf8')
      const parsed = JSON.parse(raw)
      // Tolerant decode, matching the native archive's convention: a missing or
      // malformed field falls back to its default rather than failing the load.
      this.state = {
        schemaVersion: 1,
        rooms: (Array.isArray(parsed.rooms) ? parsed.rooms : [])
          .filter(room => room && typeof room === 'object' && room.id)
          .map(room => ({
            ...room,
            name: typeof room.name === 'string' ? room.name : 'Room',
            lightIDs: Array.isArray(room.lightIDs) ? room.lightIDs.map(String) : [],
            schedules: (Array.isArray(room.schedules) ? room.schedules : []).filter(
              s => s && typeof s === 'object' && s.id,
            ),
          })),
        scenes: (Array.isArray(parsed.scenes) ? parsed.scenes : []).filter(
          scene =>
            scene &&
            typeof scene === 'object' &&
            scene.id &&
            scene.snapshots &&
            typeof scene.snapshots === 'object',
        ),
        favorites: Array.isArray(parsed.favorites) ? parsed.favorites.map(String) : [],
        deviceNames:
          parsed.deviceNames && typeof parsed.deviceNames === 'object' ? parsed.deviceNames : {},
      }
    } catch (err) {
      if (err.code !== 'ENOENT') this.log(`could not read ${this.file}: ${err.message}`)
      this.state = { ...EMPTY, rooms: [], scenes: [], favorites: [], deviceNames: {} }
    }
    return this.state
  }

  /** Writes are coalesced; a save during a save queues exactly one more. */
  save() {
    if (this.writing) {
      this.pending = true
      return this.writing
    }
    this.writing = this.#write()
      .then(() => {
        this.lastWriteError = null
      })
      .catch(err => {
        // Remembered rather than thrown here, because callers are synchronous.
        // flush() surfaces it so a request never reports success for a change
        // that only exists in memory.
        this.lastWriteError = err
        this.log(`could not write ${this.file}: ${err.message}`)
      })
      .finally(() => {
        this.writing = null
        if (this.pending) {
          this.pending = false
          this.save()
        }
      })
    return this.writing
  }

  /** Await the pending write and throw if persistence actually failed. */
  async flush() {
    while (this.writing) await this.writing
    if (this.lastWriteError) {
      const err = this.lastWriteError
      this.lastWriteError = null
      throw new Error(`could not save state: ${err.message}`)
    }
  }

  async #write() {
    await fsp.mkdir(path.dirname(this.file), { recursive: true })
    const tmp = `${this.file}.tmp`
    await fsp.writeFile(tmp, JSON.stringify(this.state, null, 2))
    await fsp.rename(tmp, this.file) // atomic: never leave a half-written file
  }

  // MARK: rooms

  listRooms() {
    return this.state.rooms
  }

  addRoom(name) {
    const room = { id: id(), name: String(name || 'Room').slice(0, 60), lightIDs: [], schedules: [] }
    this.state.rooms.push(room)
    this.save()
    return room
  }

  updateRoom(roomID, patch) {
    const room = this.state.rooms.find(r => r.id === roomID)
    if (!room) return null
    if (typeof patch.name === 'string') room.name = patch.name.slice(0, 60)
    if (Array.isArray(patch.lightIDs)) room.lightIDs = [...new Set(patch.lightIDs.map(String))]
    this.save()
    return room
  }

  removeRoom(roomID) {
    const before = this.state.rooms.length
    this.state.rooms = this.state.rooms.filter(r => r.id !== roomID)
    if (this.state.rooms.length === before) return false
    this.save()
    return true
  }

  /** A light belongs to at most one room, like the native app. */
  assignLight(deviceID, roomID) {
    // Resolve the destination first: a failed lookup must not have already
    // stripped the light from the room it was in.
    const destination = roomID ? this.state.rooms.find(r => r.id === roomID) : null
    if (roomID && !destination) return false

    for (const room of this.state.rooms) {
      room.lightIDs = room.lightIDs.filter(x => x !== deviceID)
    }
    if (destination) destination.lightIDs.push(deviceID)
    this.save()
    return true
  }

  // MARK: scenes

  listScenes() {
    return this.state.scenes
  }

  addScene(name, snapshots) {
    const scene = {
      id: id(),
      name: String(name || 'Scene').slice(0, 60),
      snapshots,
      createdAt: new Date().toISOString(),
    }
    this.state.scenes.push(scene)
    this.save()
    return scene
  }

  removeScene(sceneID) {
    const before = this.state.scenes.length
    this.state.scenes = this.state.scenes.filter(s => s.id !== sceneID)
    if (this.state.scenes.length === before) return false
    this.save()
    return true
  }

  // MARK: schedules (owned by a room, as in the native model)

  addSchedule(roomID, entry) {
    const room = this.state.rooms.find(r => r.id === roomID)
    if (!room) return null
    const schedule = {
      id: id(),
      isEnabled: entry.isEnabled !== false,
      hour: Math.max(0, Math.min(23, Number(entry.hour) || 0)),
      minute: Math.max(0, Math.min(59, Number(entry.minute) || 0)),
      action: entry.action,
      weekdays: Array.isArray(entry.weekdays) && entry.weekdays.length ? entry.weekdays : [1, 2, 3, 4, 5, 6, 7],
      sceneID: entry.sceneID ?? null,
    }
    room.schedules.push(schedule)
    this.save()
    return schedule
  }

  updateSchedule(roomID, scheduleID, patch) {
    const room = this.state.rooms.find(r => r.id === roomID)
    const schedule = room?.schedules.find(s => s.id === scheduleID)
    if (!schedule) return null
    if (typeof patch.isEnabled === 'boolean') schedule.isEnabled = patch.isEnabled
    if (patch.hour !== undefined) schedule.hour = Math.max(0, Math.min(23, Number(patch.hour) || 0))
    if (patch.minute !== undefined) schedule.minute = Math.max(0, Math.min(59, Number(patch.minute) || 0))
    if (patch.action) schedule.action = patch.action
    if (Array.isArray(patch.weekdays)) schedule.weekdays = patch.weekdays
    if ('sceneID' in patch) schedule.sceneID = patch.sceneID
    this.save()
    return schedule
  }

  removeSchedule(roomID, scheduleID) {
    const room = this.state.rooms.find(r => r.id === roomID)
    if (!room) return false
    const before = room.schedules.length
    room.schedules = room.schedules.filter(s => s.id !== scheduleID)
    if (room.schedules.length === before) return false
    this.save()
    return true
  }

  // MARK: favourites and naming

  toggleFavorite(deviceID) {
    const set = new Set(this.state.favorites)
    if (set.has(deviceID)) set.delete(deviceID)
    else set.add(deviceID)
    this.state.favorites = [...set]
    this.save()
    return set.has(deviceID)
  }

  renameDevice(deviceID, name) {
    if (name) this.state.deviceNames[deviceID] = String(name).slice(0, 60)
    else delete this.state.deviceNames[deviceID]
    this.save()
    return this.state.deviceNames[deviceID] ?? null
  }
}
