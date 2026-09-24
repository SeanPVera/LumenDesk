import { chromium } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { spawn } from 'node:child_process'
import { mkdir, writeFile } from 'node:fs/promises'
import assert from 'node:assert/strict'

const output = process.env.LUMENDESK_WEB_QA_DIRECTORY ?? '/tmp/LumenDesk-Web-QA'
await mkdir(output, { recursive: true })
const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '4174'], { stdio: 'pipe' })
const browser = await chromium.launch()
const context = await browser.newContext({ viewport: { width: 1100, height: 900 }, colorScheme: 'dark' })
const page = await context.newPage()
const errors = []
page.on('pageerror', error => errors.push(error.message))
const devices = [
  {id:'lifx:one',name:'Reading lamp',brand:'lifx',ip:'192.0.2.1',reachable:true,power:true,brightness:65,color:{r:255,g:190,b:100},kelvin:3000,roomID:'lounge'},
  {id:'govee:two',name:'Bookshelf light with a deliberately long fixture name',brand:'govee',ip:'192.0.2.2',reachable:true,power:true,brightness:35,color:{r:83,g:152,b:182},kelvin:4000,roomID:'lounge'},
  {id:'lifx:three',name:'Corner lamp',brand:'lifx',ip:'192.0.2.3',reachable:false,power:true,brightness:50,color:{r:220,g:180,b:120},kelvin:3200,roomID:'lounge'},
  {id:'lifx:office',name:'Desk',brand:'lifx',ip:'192.0.2.4',reachable:true,power:false,brightness:60,color:{r:220,g:235,b:255},kelvin:6000,roomID:'office'},
]
const state = {devices,rooms:[{id:'lounge',name:'Living room',lightIDs:devices.slice(0,3).map(d=>d.id),schedules:[]},{id:'office',name:'Office',lightIDs:['lifx:office'],schedules:[]}],
 scenes:[{id:'evening',name:'Late reading',createdAt:'2026-09-24T00:00:00Z',snapshots:Object.fromEntries(devices.slice(0,2).map(d=>[d.id,d]))}],favorites:[]}
const commands = []
let unavailable = false
await page.route('**/*', async route => {
  const url = new URL(route.request().url())
  const path = url.pathname
  if (!['/health','/state','/discover','/scenes','/music/frame'].includes(path) && !path.startsWith('/devices/') && !path.startsWith('/scenes/')) return route.continue()
  if (unavailable) return route.abort('connectionrefused')
  let body = {}
  if (path === '/health') body = {ok:true,service:'lumendesk-bridge'}
  if (path === '/state') body = state
  if (route.request().method() === 'POST') {
    const data = route.request().postData() ? route.request().postDataJSON() : {}
    commands.push({path,data})
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
try {
  for(let i=0;i<80;i++){try{await fetch('http://127.0.0.1:4174');break}catch{await new Promise(r=>setTimeout(r,100))}}
  await page.goto('http://127.0.0.1:4174')
  await page.getByLabel('Control room').selectOption('lounge')
  await page.getByRole('heading',{name:'Fixtures',exact:true}).waitFor()
  await capture('web-room-1100')
  await capture('web-room-1440',1440,950)
  await capture('web-room-620',620,850)
  await capture('web-room-390',390,844)
  const axe = await new AxeBuilder({page}).analyze()
  await writeFile(output+'/accessibility.json',JSON.stringify(axe,null,2))
  console.log('ACCESSIBILITY',JSON.stringify(axe.violations.map(v=>({id:v.id,impact:v.impact,nodes:v.nodes.length}))))
  assert.equal(axe.violations.filter(v=>['critical','serious'].includes(v.impact)).length,0,'Room has serious accessibility violations')
  await page.setViewportSize({width:1100,height:900})
  await page.getByRole('button',{name:/Reading lamp, .*on/}).click()
  await page.getByRole('button',{name:/Bookshelf light.*on/}).click()
  await capture('web-selection')
  commands.length=0
  await page.getByRole('button',{name:'Off',exact:true}).click()
  await page.waitForTimeout(200)
  assert.deepEqual(commands.filter(x=>x.path.endsWith('/power')).map(x=>decodeURIComponent(x.path.split('/')[2])).sort(),['govee:two','lifx:one'])
  await page.getByRole('button',{name:'Compositions',exact:true}).click()
  await page.getByPlaceholder('Scene name, e.g. Evening').fill('Room capture')
  await page.getByRole('button',{name:'Save scene',exact:true}).click()
  await page.waitForTimeout(100)
  assert.deepEqual(commands.find(x=>x.path==='/scenes').data.deviceIDs.sort(),['govee:two','lifx:one','lifx:three'])
  await capture('web-scenes')
  await page.getByRole('button',{name:'Music',exact:true}).click()
  await page.getByRole('slider',{name:/^Intensity/}).press('Home')
  await page.getByText('Custom balance. Choosing a preset replaces these adjustments.').waitFor()
  await page.getByRole('button',{name:'Move Reading lamp later',exact:true}).click()
  assert.match(await page.locator('.fixture-list li').first().innerText(),/Bookshelf/)
  await capture('web-music-stopped')
  await capture('web-music-390',390,844)
  await page.setViewportSize({width:1100,height:900})
  await page.getByRole('button',{name:'Demo groove',exact:true}).click()
  await page.getByText(/Running · Demo groove/).waitFor()
  assert.equal(await page.getByLabel('Control room').isDisabled(),true)
  await capture('web-music-running')
  await page.getByRole('button',{name:'Stop',exact:true}).click()
  await page.getByRole('button',{name:'Light',exact:true}).click()
  await page.emulateMedia({reducedMotion:'reduce'})
  await capture('web-reduced-motion',620,850)
  state.devices=[]
  await page.reload()
  await page.getByRole('heading',{name:'No lights found yet'}).waitFor()
  await capture('web-empty')
  unavailable=true
  await page.reload()
  await page.getByRole('heading',{name:'Connect your local lights'}).waitFor()
  await capture('web-connection-unavailable',620,850)
  assert.deepEqual(errors,[],'Browser runtime errors')
  console.log('UI_ASSERTIONS_PASS: scope, multi-selection, scoped scene capture, music scope lock, overflow, runtime errors, room accessibility')
} finally {
  await writeFile(output+'/review-states.json',JSON.stringify(results,null,2))
  await browser.close()
  server.kill()
}
