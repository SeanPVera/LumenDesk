import { chromium, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { spawn } from 'node:child_process'
import { mkdir, writeFile } from 'node:fs/promises'
import assert from 'node:assert/strict'
import { drawingGeometry, parseTopology } from '../../bridge/src/nanoleaf.js'
import { reviewLifecycles } from './lifecycle-review.mjs'

const output = process.env.LUMENDESK_WEB_QA_DIRECTORY ?? '/tmp/LumenDesk-Web-QA'
await mkdir(output, { recursive: true })
const executablePath = process.env.LUMENDESK_CHROMIUM_EXECUTABLE ?? process.env.LUMENDESK_CHROMIUM_PATH
const browser = await chromium.launch(executablePath ? { executablePath } : {})
const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '4174'], { stdio: 'pipe' })
const context = await browser.newContext({ viewport: { width: 1100, height: 900 }, colorScheme: 'dark' })
const page = await context.newPage()
const errors = []
page.on('pageerror', error => { errors.push(error.message); console.error('BROWSER_ERROR:',error.message) })
const devices = [
  {id:'lifx:one',name:'Reading lamp',brand:'lifx',ip:'192.0.2.1',reachable:true,power:true,brightness:65,color:{r:255,g:190,b:100},kelvin:3000,roomID:'lounge'},
  {id:'govee:two',name:'Bookshelf light with a deliberately long fixture name',brand:'govee',ip:'192.0.2.2',reachable:true,power:true,brightness:35,color:{r:83,g:152,b:182},kelvin:4000,roomID:'lounge'},
  {id:'lifx:three',name:'Corner lamp',brand:'lifx',ip:'192.0.2.3',reachable:false,power:true,brightness:50,color:{r:220,g:180,b:120},kelvin:3200,roomID:'lounge'},
  {id:'lifx:office',name:'Desk',brand:'lifx',ip:'192.0.2.4',reachable:true,power:false,brightness:60,color:{r:220,g:235,b:255},kelvin:6000,roomID:'office'},
]
// A Shapes wall as the bridge reports it: the layout goes through the bridge's
// own parser and geometry, so the page draws exactly what a real reading gives.
const shapesLayout = parseTopology({ panelLayout: { globalOrientation: { value: 240, max: 360, min: 0 }, layout: { positionData: [
  { panelId: 5120, x: 0, y: 0, o: 0, shapeType: 7 }, { panelId: 77, x: 100.5, y: 58.02, o: 0, shapeType: 7 },
  { panelId: 31000, x: -100.5, y: 58.02, o: 120, shapeType: 7 }, { panelId: 1204, x: 67, y: -38.68, o: 0, shapeType: 9 },
  { panelId: 9, x: -67, y: -38.68, o: 0, shapeType: 9 }, { panelId: 64001, x: 0, y: -96.7, o: 60, shapeType: 8 },
  { panelId: 4410, x: 0, y: 116.04, o: 0, shapeType: 7 }, { panelId: 812, x: 100.5, y: 174.06, o: 0, shapeType: 7 },
  { panelId: 23001, x: -100.5, y: 174.06, o: 0, shapeType: 7 }, { panelId: 6, x: 0, y: 232.08, o: 0, shapeType: 7 },
  { panelId: 0, x: -170, y: 10, o: 0, shapeType: 12 },
] } } })
const shapesWall = {id:'nanoleaf:SHAPES123',name:'Studio Shapes',brand:'nanoleaf',ip:'192.0.2.9',reachable:true,power:true,brightness:70,
  color:{r:255,g:120,b:40},kelvin:null,roomID:'lounge',needsPairing:false,
  shapes:{layout:shapesLayout.layout,geometry:drawingGeometry(shapesLayout.layout),orientation:240,orientationReport:shapesLayout.orientation,
    orientationPending:null,output:'design',effect:null,effects:['Northern Lights','Evening','Fireplace'],firmware:'9.2.0',problem:null,lastFailure:null,
    design:{5120:{r:255,g:106,b:43},77:{r:56,g:232,b:212},31000:{r:128,g:53,b:22},1204:{r:0,g:0,b:0},9:{r:255,g:214,b:150},
      64001:{r:90,g:40,b:200},4410:{r:255,g:106,b:43},812:{r:56,g:232,b:212},23001:{r:20,g:60,b:180},6:{r:255,g:255,b:255}}}}
devices.push(shapesWall)
const state = {devices,rooms:[{id:'lounge',name:'Living room',lightIDs:[...devices.slice(0,3).map(d=>d.id),shapesWall.id],schedules:[]},{id:'office',name:'Office',lightIDs:['lifx:office'],schedules:[]}],
 scenes:[{id:'evening',name:'Late reading',createdAt:'2026-09-24T00:00:00Z',snapshots:Object.fromEntries(devices.slice(0,2).map(d=>[d.id,structuredClone(d)]))}],favorites:[]}
const commands = []
let unavailable = false
let failingPath = null
let delayedPath = null
let sceneResult = {applied:['lifx:one'],skipped:['govee:two']}
const refusedPower = new Set()
await page.route('**/*', async route => {
  const url = new URL(route.request().url())
  const path = url.pathname
  if (!['/health','/state','/discover','/scenes','/rooms','/music/frame','/nanoleaf/pair'].includes(path) && !path.startsWith('/devices/') && !path.startsWith('/scenes/') && !path.startsWith('/rooms/')) return route.continue()
  if (unavailable) return route.abort('connectionrefused')
  let body = {}
  if (path === '/health') body = {ok:true,service:'lumendesk-bridge'}
  if (path === '/state') body = state
  if (route.request().method() === 'POST') {
    const data = route.request().postData() ? route.request().postDataJSON() : {}
    commands.push({path,data})
    if (path === delayedPath) await new Promise(resolve=>setTimeout(resolve,400))
    if (path === failingPath || (path.endsWith('/power') && refusedPower.has(decodeURIComponent(path.split('/')[2])))) {
      await route.fulfill({status:503,json:{error:'Simulated command failure; try again.'}})
      return
    }
    const match = path.match(/^\/devices\/([^/]+)\/(power|brightness|color)$/)
    if (match) {
      const d = state.devices.find(d=>d.id === decodeURIComponent(match[1]))
      if (d) {
        if (match[2] === 'power') d.power = data.on
        if (match[2] === 'brightness') d.brightness = data.value
        if (data.rgb) d.color = data.rgb
        if (data.kelvin) d.kelvin = data.kelvin
        body = {device:d}
      }
    }
    if (path === '/scenes') body = {scene:state.scenes[0]}
    if (path.endsWith('/apply')) body = {...sceneResult,devices:state.devices}
    if (path === '/rooms') {
      const room = {id:'test-room',name:data.name,lightIDs:[],schedules:[]}
      state.rooms.push(room)
      body = {room}
    }
    if (path.startsWith('/rooms/') && url.searchParams.has('delete')) {
      state.rooms = state.rooms.filter(room=>room.id !== path.split('/')[2])
      body = {ok:true}
    }
    if (path.endsWith('/schedules')) {
      const room = state.rooms.find(room=>room.id === path.split('/')[2])
      const schedule = {id:'test-schedule',isEnabled:true,...data}
      room.schedules.push(schedule)
      body = {schedule}
    }
    const shapes = path.match(/^\/devices\/([^/]+)\/(orientation|panels|effect|identify)$/)
    const wall = shapes && state.devices.find(d=>d.id === decodeURIComponent(shapes[1]))
    if (wall) {
      if (shapes[2] === 'orientation') wall.shapes.orientationPending = ((data.degrees % 360) + 360) % 360
      if (shapes[2] === 'panels') Object.assign(wall.shapes, {output:'design',effect:null,design:data.colors})
      if (shapes[2] === 'effect') Object.assign(wall.shapes, {output:'effect',effect:data.name,design:null})
      body = shapes[2] === 'identify' ? {ok:true} : {device:wall}
    }
    if (path === '/nanoleaf/pair') { await route.fulfill({status:403,json:{error:'Hold the controller’s power button for 5–7 seconds until its LED flashes, then pair within 30 seconds.'}}); return }
  }
  await route.fulfill({json:body})
})
const results = []
async function capture(name, width = 1100, height = 900) {
  await page.setViewportSize({width,height})
  await page.screenshot({path:output+'/'+name+'.png',fullPage:true})
  const jpg = await page.screenshot({type:'jpeg',quality:75,fullPage:true})
  console.log('LUMEN_VISUAL_BEGIN|'+name+'|'+width+'x'+height)
  console.log(jpg.toString('base64'))
  console.log('LUMEN_VISUAL_END|'+name)
  const overflow = await page.evaluate(()=>document.documentElement.scrollWidth > innerWidth + 1)
  assert.equal(overflow,false,name+' overflows horizontally')
  results.push({name,width,height,overflow})
}
async function audit(name) {
  const axe = await new AxeBuilder({page}).analyze()
  await writeFile(output+'/accessibility-'+name+'.json',JSON.stringify(axe,null,2))
  console.log('ACCESSIBILITY '+name,JSON.stringify(axe.violations.map(v=>({id:v.id,impact:v.impact,nodes:v.nodes.length}))))
  assert.equal(axe.violations.length,0,name+' has accessibility violations')
}
try {
  for(let i=0;i<80;i++){try{await fetch('http://127.0.0.1:4174');break}catch{await new Promise(r=>setTimeout(r,100))}}
  await page.goto('http://127.0.0.1:4174')
  await page.getByLabel('Control room').selectOption('lounge')
  await page.getByRole('heading',{name:'Fixtures',exact:true}).waitFor()
  await capture('web-room-1100')
  await capture('web-room-1440',1440,950)
  await capture('web-room-620',620,850)
  await capture('web-room-390',390,844)
  await capture('web-room-320',320,568)
  await page.getByRole('searchbox', { name: 'Find a fixture' }).fill('Reading lamp')
  const searchPosition = await page.getByRole('searchbox', { name: 'Find a fixture' }).boundingBox()
  const controlsPosition = await page.locator('.output-controls').boundingBox()
  assert.ok(controlsPosition.y - searchPosition.y < 500, 'mobile search, fixture selection and output controls stay together')
  await page.getByRole('searchbox', { name: 'Find a fixture' }).fill('')
  await audit('room')
  // Every slider has a name: a wrapping label with an <output> in it names the output instead.
  assert.deepEqual(await page.getByRole('slider').evaluateAll(nodes=>nodes.filter(n=>!n.labels?.length || n.labels[0].control!==n).length),0)
  assert.equal(await page.getByRole('slider',{name:/^Brightness/}).count(),1)
  await page.setViewportSize({width:1100,height:900})
  await page.getByRole('button',{name:/Reading lamp, .*on/}).click()
  await page.getByRole('button',{name:/^Bookshelf light.*on/}).click()
  await capture('web-selection')
  commands.length=0
  await page.getByRole('button',{name:'Off',exact:true}).click()
  await page.waitForTimeout(200)
  assert.deepEqual(commands.filter(x=>x.path.endsWith('/power')).map(x=>decodeURIComponent(x.path.split('/')[2])).sort(),['govee:two','lifx:one'])
  // Basic output changes must use the same selected fixtures as power.
  commands.length=0
  await page.getByRole('slider',{name:/^Brightness/}).fill('43')
  await expect.poll(()=>commands.filter(command=>command.path.endsWith('/brightness')).length).toBe(2)
  assert.deepEqual(commands.filter(command=>command.path.endsWith('/brightness')).map(command=>[decodeURIComponent(command.path.split('/')[2]),command.data.value]).sort(),[['govee:two',43],['lifx:one',43]])
  commands.length=0
  await page.locator('.color-control input[type=color]').fill('#3366ff')
  await expect.poll(()=>commands.filter(command=>command.path.endsWith('/color')).length).toBe(2)
  for (const command of commands.filter(command=>command.path.endsWith('/color'))) assert.deepEqual(command.data.rgb,{r:51,g:102,b:255})
  commands.length=0
  await page.getByRole('slider',{name:/^White temperature/}).fill('4000')
  await expect.poll(()=>commands.filter(command=>command.path.endsWith('/color')).length).toBe(2)
  for (const command of commands.filter(command=>command.path.endsWith('/color'))) assert.equal(command.data.kelvin,4000)
  assert.equal(state.devices.find(device=>device.id === 'nanoleaf:SHAPES123').brightness,70,'unselected wall remains unchanged')
  assert.equal(state.devices.find(device=>device.id === 'lifx:office').power,false,'another room remains unchanged')
  await page.getByRole('button',{name:'Scenes',exact:true}).click()
  // A rejected save must keep the user's name and reject duplicate submissions.
  failingPath = delayedPath = '/scenes'
  const sceneName = page.getByPlaceholder('Scene name, e.g. Evening')
  await sceneName.fill('Keep my scene')
  commands.length=0
  await page.getByRole('button',{name:'Save scene',exact:true}).click()
  await expect(page.getByRole('button',{name:'Saving…',exact:true})).toBeDisabled()
  await sceneName.evaluate(input=>input.form.requestSubmit())
  await expect(page.getByRole('alert')).toContainText('Simulated command failure')
  assert.equal(commands.filter(command=>command.path === '/scenes').length,1)
  await expect(sceneName).toHaveValue('Keep my scene')
  failingPath = delayedPath = null
  commands.length=0
  await page.getByPlaceholder('Scene name, e.g. Evening').fill('Room capture')
  await page.getByRole('button',{name:'Save scene',exact:true}).click()
  await page.waitForTimeout(100)
  assert.deepEqual(commands.find(x=>x.path==='/scenes').data.deviceIDs.sort(),['govee:two','lifx:one','lifx:three','nanoleaf:SHAPES123'])
  await expect(sceneName).toHaveValue('')
  await page.getByRole('button',{name:'Apply',exact:true}).click()
  await expect(page.locator('.toast')).toContainText('sent to 1 light · 1 skipped')
  await capture('web-scenes')
  await audit('scenes')
  await page.getByRole('button',{name:'Music',exact:true}).click()
  await page.evaluate(() => {
    window.reviewCaptureRequests = 0
    navigator.mediaDevices.getUserMedia = async () => { window.reviewCaptureRequests++; throw new Error('Review microphone permission denied') }
    navigator.requestMIDIAccess = async () => { window.reviewCaptureRequests++; throw new Error('Review MIDI permission denied') }
  })
  const framesBeforeSetup = commands.filter(command => command.path === '/music/frame').length
  await page.getByRole('button',{name:'Microphone',exact:true}).click()
  await page.getByRole('button',{name:'MIDI clock',exact:true}).click()
  await page.getByRole('button',{name:'Audio file',exact:true}).click()
  assert.equal(await page.evaluate(() => window.reviewCaptureRequests), 0, 'selecting a source must not request capture access')
  assert.equal(commands.filter(command => command.path === '/music/frame').length, framesBeforeSetup, 'setup must not send light frames')
  await page.getByRole('button',{name:'Microphone',exact:true}).click()
  await page.getByRole('button',{name:'Start',exact:true}).click()
  await expect(page.getByRole('alert')).toContainText('Review microphone permission denied')
  assert.equal(await page.evaluate(() => window.reviewCaptureRequests), 1, 'Start requests access')
  await page.getByRole('button',{name:'Demo groove',exact:true}).click()
  await capture('web-music-initial')
  await page.getByRole('slider',{name:'Intensity',exact:true}).press('Home')
  await page.getByText('Custom balance. Choosing a preset replaces these adjustments.').waitFor()
  await page.getByRole('button',{name:'Move Reading lamp later',exact:true}).click()
  assert.match(await page.locator('.fixture-list li').first().innerText(),/Bookshelf/)
  await capture('web-music-stopped')
  await capture('web-music-390',390,844)
  assert.equal(await page.locator('.music-transport-controls').evaluate(element => getComputedStyle(element).position), 'static', 'setup controls must not cover the light selection')
  await audit('music')
  await page.setViewportSize({width:1100,height:900})
  await page.getByRole('button',{name:'Demo groove',exact:true}).click()
  await page.getByRole('button',{name:'Start',exact:true}).click()
  await page.getByText(/Running · Demo groove/).waitFor()
  assert.equal(await page.locator('.music-transport-controls').evaluate(element => getComputedStyle(element).position), 'sticky', 'Stop stays available during the show')
  assert.equal(await page.getByLabel('Control room').isDisabled(),true)
  await capture('web-music-running')
  await capture('web-music-running-320',320,568)
  assert.ok((await page.locator('.music-transport-controls').boundingBox()).height < 150,
    'mobile sticky transport stays compact')
  await page.setViewportSize({width:1100,height:900})
  await page.getByRole('button',{name:'Stop',exact:true}).click()
  await expect(page.getByRole('heading',{name:'Set up your music show'})).toBeVisible()
  // A failed Stop retains its original restoration across navigation and
  // prevents a new show from adopting the unfinished output as its baseline.
  await page.getByRole('button',{name:'Demo groove',exact:true}).click()
  await page.getByRole('button',{name:'Start',exact:true}).click()
  await page.getByText(/Running · Demo groove/).waitFor()
  failingPath = '/music/frame'
  await page.getByRole('button',{name:'Stop',exact:true}).click()
  await expect(page.getByRole('alert')).toContainText('Simulated command failure')
  await expect(page.getByText(/Sending the starting light output back is still pending/)).toBeVisible()
  await capture('web-music-restore-pending')
  const liveFramesBefore = commands.filter(command=>command.path === '/music/frame' && command.data.states.some(state=>!state.restoring)).length
  await page.getByRole('button',{name:'Start',exact:true}).click()
  await expect(page.getByRole('heading',{name:'Set up your music show'})).toBeVisible()
  assert.equal(commands.filter(command=>command.path === '/music/frame' && command.data.states.some(state=>!state.restoring)).length,liveFramesBefore)
  await page.getByRole('button',{name:'Light',exact:true}).click()
  const restoresBefore = commands.filter(command=>command.path === '/music/frame' && command.data.states.every(state=>state.restoring)).length
  failingPath = null
  await expect.poll(()=>commands.filter(command=>command.path === '/music/frame' && command.data.states.every(state=>state.restoring)).length).toBeGreaterThan(restoresBefore)
  await page.getByRole('button',{name:'Music',exact:true}).click()
  await expect(page.getByText(/still pending/)).toHaveCount(0)
  // Disconnection while running stops capture; restoration retries from App
  // even when the user leaves Music before the bridge becomes available.
  await page.getByRole('button',{name:'Demo groove',exact:true}).click()
  await page.getByRole('button',{name:'Start',exact:true}).click()
  await page.getByText(/Running · Demo groove/).waitFor()
  unavailable=true
  await expect(page.getByText(/Reconnecting automatically/)).toBeVisible({timeout:10000})
  await expect(page.getByRole('heading',{name:'Set up your music show'})).toBeVisible()
  await page.getByRole('button',{name:'Devices',exact:true}).click()
  const disconnectedRestores = commands.filter(command=>command.path === '/music/frame' && command.data.states.every(state=>state.restoring)).length
  unavailable=false
  await expect(page.getByText(/Reconnecting automatically/)).toHaveCount(0,{timeout:10000})
  await expect.poll(()=>commands.filter(command=>command.path === '/music/frame' && command.data.states.every(state=>state.restoring)).length).toBeGreaterThan(disconnectedRestores)
  await page.getByRole('button',{name:'Room',exact:true}).click()
  await page.getByRole('button',{name:'Light',exact:true}).click()

  // Shapes: one wall selected on its own opens its panels in the room.
  await page.getByRole('button',{name:/^Studio Shapes, /}).click()
  const wallCanvas = page.getByRole('group',{name:/Studio Shapes, 10 panels drawn as they hang/})
  await wallCanvas.waitFor()
  await capture('web-shapes-1100')
  await capture('web-shapes-1440',1440,950)
  await capture('web-shapes-390',390,844)
  await audit('shapes')
  await page.setViewportSize({width:1100,height:900})
  const panel = n => page.getByRole('checkbox',{name:new RegExp(`^Panel ${n},`)})
  assert.equal(await page.getByRole('checkbox',{name:/^Panel \d+,/}).count(),10,'every light panel and never the controller')
  // Keyboard: one tab stop, arrows move across the wall as it hangs.
  await panel(1).focus()
  await page.keyboard.press('Space')
  await page.keyboard.press('ArrowRight')
  const moved = await page.evaluate(()=>document.activeElement?.getAttribute('aria-label'))
  assert.ok(moved && !moved.startsWith('Panel 1,'),'arrow keys move to a neighbouring panel')
  await page.keyboard.press('Space')
  await page.getByText('2 of 10 selected').waitFor()
  assert.equal(await panel(1).getAttribute('aria-checked'),'true')
  assert.equal(await page.locator('.shapes-panel[tabindex="0"]').count(),1,'the wall is one tab stop')
  // Paint the two selected panels; the rest keep the design.
  const selectedIDs = await page.locator('.shapes-panel[aria-checked="true"]').evaluateAll(nodes=>nodes.map(n=>n.getAttribute('aria-label')))
  await page.getByRole('button',{name:'Paint from what the wall shows'}).click()
  await page.getByLabel('Hex',{exact:true}).fill('#3050FF')
  await page.getByRole('button',{name:'Set',exact:true}).click()
  await page.getByRole('slider',{name:'Panel level',exact:true}).fill('50')
  await page.getByRole('button',{name:'Undo',exact:true}).click()
  // History is now [start] <- Set -> [level 50]. Undo inside a text field
  // belongs to the field; from the wall it walks the draft's history.
  const undoButton = page.getByRole('button',{name:'Undo',exact:true})
  const levelSlider = page.getByRole('slider',{name:'Panel level',exact:true})
  const firstPanel = page.getByRole('checkbox',{name:/^Panel 1,/})
  await page.getByRole('spinbutton',{name:'Degrees'}).press('Control+z')
  assert.equal(await undoButton.isEnabled(),true,'a field’s own undo leaves the draft alone')
  await firstPanel.press('Control+z')
  assert.equal(await undoButton.isEnabled(),false,'undo from the wall stepped back past Set')
  await firstPanel.press('Control+Shift+z')
  await firstPanel.press('Control+Shift+z')
  assert.equal(await levelSlider.inputValue(),'50','redo from the wall brings both steps back')
  await undoButton.click()
  assert.equal(await levelSlider.inputValue(),'100')
  await capture('web-shapes-draft')
  commands.length=0
  const designBefore = structuredClone(shapesWall.shapes.design)
  failingPath = '/devices/nanoleaf%3ASHAPES123/panels'
  await page.getByRole('button',{name:'Apply to wall'}).click()
  await expect(page.getByRole('status').filter({hasText:'Simulated command failure'})).toBeVisible()
  await expect(page.getByRole('button',{name:'Apply to wall'})).toBeEnabled()
  await expect(page.getByRole('button',{name:'Undo',exact:true})).toBeEnabled()
  failingPath = null
  commands.length=0
  await page.getByRole('button',{name:'Apply to wall'}).click()
  await page.getByText('Applied. The wall confirms it on its next reading.').waitFor()
  const painted = commands.find(x=>x.path.endsWith('/panels'))
  assert.equal(Object.keys(painted.data.colors).length,10,'a design covers every light panel')
  const blue = Object.entries(painted.data.colors).filter(([,c])=>c.r===48&&c.g===80&&c.b===255).map(([id])=>Number(id))
  assert.equal(blue.length,2,'exactly the selected panels were painted: '+selectedIDs.join(' / '))
  for (const [id,color] of Object.entries(painted.data.colors)) {
    if (!blue.includes(Number(id))) assert.deepEqual(color,designBefore[id],`unselected panel ${id} keeps the design`)
  }
  // Orientation: turn, see it numbered the new way, apply, wait for the readback.
  await page.getByRole('button',{name:'Turn 90 degrees clockwise'}).click()
  assert.equal(await page.getByRole('spinbutton',{name:'Degrees'}).inputValue(),'330')
  failingPath = '/devices/nanoleaf%3ASHAPES123/orientation'
  await page.getByRole('button',{name:'Apply orientation'}).click()
  await expect(page.getByRole('status').filter({hasText:'Simulated command failure'})).toBeVisible()
  await expect(page.getByRole('spinbutton',{name:'Degrees'})).toHaveValue('330')
  await expect(page.getByRole('button',{name:'Apply orientation'})).toBeEnabled()
  failingPath = null
  commands.length=0
  await page.getByRole('button',{name:'Apply orientation'}).click()
  await page.getByText('330° requested, waiting for the controller to confirm').waitFor()
  assert.deepEqual(commands.find(x=>x.path.endsWith('/orientation')).data,{degrees:330})
  await capture('web-shapes-orientation-pending')
  // A controller scene makes panel colours unknowable, and the page says so.
  await page.getByRole('listitem').filter({hasText:'Evening'}).getByRole('button',{name:'Play'}).click()
  await page.getByText(/Playing the controller scene “Evening”/).first().waitFor()
  assert.equal(await page.getByRole('checkbox',{name:/colour unknown/}).count(),10)
  await capture('web-shapes-scene')
  await audit('shapes-scene')
  await page.getByRole('button',{name:'Devices',exact:true}).click()
  await page.getByLabel('Controller address').fill('192.0.2.9')
  await page.getByRole('button',{name:'Pair',exact:true}).click()
  await page.getByRole('alert').filter({hasText:'power button'}).waitFor()
  await capture('web-devices-shapes')
  await capture('web-devices-shapes-390',390,844)
  await audit('devices')
  await page.setViewportSize({width:1100,height:900})
  // A brief bridge outage keeps the current form mounted and reconnects itself.
  const roomName = page.getByPlaceholder('Room name, e.g. Studio')
  await roomName.fill('Keep my room')
  unavailable=true
  await expect(page.getByText(/Reconnecting automatically/)).toBeVisible({timeout:10000})
  await expect(roomName).toHaveValue('Keep my room')
  await expect(page.getByRole('button',{name:'Add room',exact:true})).toBeDisabled()
  await capture('web-reconnecting')
  unavailable=false
  await expect(page.getByText(/Reconnecting automatically/)).toHaveCount(0,{timeout:10000})
  await expect(roomName).toHaveValue('Keep my room')
  await expect(page.getByRole('button',{name:'Add room',exact:true})).toBeEnabled()
  failingPath = delayedPath = '/rooms'
  commands.length=0
  await page.getByRole('button',{name:'Add room',exact:true}).click()
  await expect(page.getByRole('button',{name:'Adding…',exact:true})).toBeDisabled()
  await roomName.evaluate(input=>input.form.requestSubmit())
  await expect(page.getByRole('alert').filter({hasText:'Simulated command failure'})).toBeVisible()
  assert.equal(commands.filter(command=>command.path === '/rooms').length,1)
  await expect(roomName).toHaveValue('Keep my room')
  failingPath = delayedPath = null
  await page.getByRole('button',{name:'Add room',exact:true}).click()
  await expect(roomName).toHaveValue('')
  await expect(page.getByRole('button',{name:'Delete Keep my room',exact:true})).toBeVisible()
  // Cancel means the room survives; confirm removes it.
  commands.length=0
  page.once('dialog',dialog=>dialog.dismiss())
  await page.getByRole('button',{name:'Delete Keep my room',exact:true}).click()
  assert.equal(commands.filter(command=>command.path.startsWith('/rooms/')).length,0)
  page.once('dialog',async dialog=>{
    assert.match(dialog.message(),/cannot be undone/i)
    await dialog.accept()
  })
  await page.getByRole('button',{name:'Delete Keep my room',exact:true}).click()
  await expect(page.getByRole('button',{name:'Delete Keep my room',exact:true})).toHaveCount(0)
  await page.getByRole('button',{name:'Schedules',exact:true}).click()
  await page.getByLabel('Schedule action for Living room').selectOption('applyScene')
  await page.getByLabel('Schedule scene for Living room').selectOption('evening')
  await capture('web-schedules')
  await capture('web-schedules-390',390,844)
  await audit('schedules')
  await page.setViewportSize({width:1100,height:900})
  await page.getByLabel('Schedule action for Living room').selectOption('turnOn')
  const scheduleForm = page.locator('.group').filter({has:page.getByRole('heading',{name:/Living room/})}).locator('form')
  delayedPath = '/rooms/lounge/schedules'
  commands.length=0
  await scheduleForm.getByRole('button',{name:'Add schedule',exact:true}).click()
  await expect(scheduleForm.getByRole('button',{name:'Adding…',exact:true})).toBeDisabled()
  await scheduleForm.evaluate(form=>form.requestSubmit())
  await expect(scheduleForm.getByRole('button',{name:'Add schedule',exact:true})).toBeEnabled()
  assert.equal(commands.filter(command=>command.path === '/rooms/lounge/schedules').length,1)
  delayedPath = null
  await page.getByRole('button',{name:'Devices',exact:true}).click()
  page.once('dialog',async dialog=>{
    assert.match(dialog.message(),/4 lights will be moved to No room/)
    assert.match(dialog.message(),/1 schedule will be deleted/)
    await dialog.dismiss()
  })
  await page.getByRole('button',{name:'Delete Living room',exact:true}).click()
  await page.getByRole('button',{name:'Settings',exact:true}).click()
  await capture('web-settings')
  await audit('settings')
  await page.setViewportSize({width:1100,height:900})
  await page.getByRole('button',{name:'Room',exact:true}).click()
  await page.getByRole('heading',{name:'Fixtures',exact:true}).waitFor()
  // A mixed bulk result reports the failure and polling does not erase it.
  await page.getByRole('button',{name:/Reading lamp, /}).click()
  await page.getByRole('button',{name:/^Bookshelf light/}).click()
  refusedPower.add('govee:two')
  await page.getByRole('button',{name:'On',exact:true}).click()
  await expect(page.locator('.toast')).toContainText('On sent to 1 light · 1 failed')
  await expect(page.getByRole('alert')).toContainText('Simulated command failure')
  await page.waitForTimeout(1700)
  await expect(page.getByRole('alert')).toContainText('Simulated command failure')
  refusedPower.clear()
  await page.getByRole('button',{name:'Clear',exact:true}).click()
  await page.emulateMedia({reducedMotion:'reduce'})
  await capture('web-reduced-motion',620,850)
  state.devices=Array.from({length:24},(_,i)=>({...structuredClone(devices[i%devices.length]),id:'review:'+i,name:`Fixture ${i+1} with a long installation name`,roomID:'lounge',reachable:i%7!==0}))
  await page.reload()
  await page.getByRole('heading',{name:'Fixtures',exact:true}).waitFor()
  await capture('web-room-24-fixtures',1440,950)
  state.devices=[]
  await page.reload()
  await page.getByRole('heading',{name:'No lights found yet'}).waitFor()
  await capture('web-empty')
  unavailable=true
  await page.reload()
  await page.getByRole('heading',{name:'Connect your local lights'}).waitFor()
  await capture('web-connection-unavailable',620,850)
  await audit('setup')
  assert.deepEqual(errors,[],'Browser runtime errors')
  await reviewLifecycles(browser, 'http://127.0.0.1:4174')
  console.log('UI_ASSERTIONS_PASS: scope, multi-selection, scoped scene capture, failed save retention, duplicate submission guards, truthful partial results, automatic reconnection and retained drafts, music scope lock and failed restore recovery across navigation, Shapes selection, failed painting/orientation retention, scene states, room deletion confirmation, schedules, settings, pairing errors, overflow, runtime errors, accessibility')
} finally {
  await writeFile(output+'/review-states.json',JSON.stringify(results,null,2))
  await browser.close()
  server.kill()
}
