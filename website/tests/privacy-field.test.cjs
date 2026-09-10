const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../privacy-field.js'), 'utf8');
function setup(reducedMotion = false) {
  let observe, change, visibility, scroll, draws = 0, rasterized = 0;
  const jobs = new Map(); let next = 1;
  const context = {getImageData(){return {data:new Uint8Array(1280*2*780*2*4)};},strokeText(){},measureText(text){return {width:text.length*55};},beginPath(){},arc(){},stroke(){},moveTo(){},lineTo(){},setTransform(){}, clearRect(){draws++;}, drawImage(){}, fillText(){rasterized++;}, translate(){}, scale(){}, fillRect(){}, createRadialGradient(){return {addColorStop(){}};}};
  const canvas = () => ({getContext:()=>context});
  const properties = {};
  const bounds = {width:1280,height:2652,left:0,top:0};
  const lines = Array.from({length:6}, () => {const values = new Set();return {values,classList:{toggle(name,on){on ? values.add(name) : values.delete(name);}}};});
  const section = {querySelectorAll:()=>lines,classList:{add(){},toggle(){}},getBoundingClientRect:()=>bounds, querySelector:selector=>selector === 'canvas' ? canvas() : {style:{setProperty(name,value){properties[name]=value;}},getBoundingClientRect:()=>({left:300,top:140,width:680,height:500})}};
  const reduced = {matches:reducedMotion, addEventListener:(_,fn)=>change=fn};
  const document = {hidden:false, querySelector:()=>section, createElement:canvas, addEventListener:(name,fn)=>{if(name==='scroll')scroll=fn;else visibility=fn;}};
  vm.runInNewContext(source, {document,navigator:{},matchMedia:()=>reduced,devicePixelRatio:2, IntersectionObserver:class {constructor(fn){observe=fn;} observe(){}}, ResizeObserver:class {observe(){}},setTimeout:fn=>{const id=next++;jobs.set(id,fn);return id;},clearTimeout:id=>jobs.delete(id),requestAnimationFrame:fn=>{const id=next++;jobs.set(id,fn);return id;},cancelAnimationFrame:id=>jobs.delete(id)});
  return {jobs, reduced, document, lines, properties, scrollTo(top){bounds.top=top;scroll();}, get draws(){return draws;}, get rasterized(){return rasterized;}, show(value){observe([{isIntersecting:value}]);}, change:()=>change(), visibility:()=>visibility(), advance(){const [id,fn]=jobs.entries().next().value;jobs.delete(id);fn();}};
}
test('field initializes lazily, reuses glyph textures, and stops offscreen or hidden',()=>{
  const env=setup();assert.equal(env.draws,0);assert.equal(env.jobs.size,0);
  env.show(true);assert.ok(env.rasterized>0);assert.equal(env.jobs.size,1);
  const glyphs=env.rasterized;env.advance();env.advance();assert.equal(env.rasterized,glyphs);
  env.show(false);assert.equal(env.jobs.size,0);
  env.show(true);env.document.hidden=true;env.visibility();assert.equal(env.jobs.size,0);
  env.document.hidden=false;env.visibility();assert.equal(env.jobs.size,1);
  env.reduced.matches=true;env.change();assert.equal(env.jobs.size,0);
});
test('reduced motion produces a static field without scheduling animation',()=>{
  const env=setup(true);env.show(true);assert.ok(env.draws>0);assert.equal(env.jobs.size,0);
});

test('one message follows scroll position in both directions, not elapsed time',()=>{
  const env=setup();env.show(true);
  const current=()=>env.lines.filter(line=>line.values.has('is-current'));
  assert.equal(current().length,1);assert.equal(current()[0],env.lines[0]);
  for(let i=0;i<46;i++) env.advance();
  assert.equal(current()[0],env.lines[0]);
  // The fixture stage is 500px tall, leaving 2152px of scroll travel.
  for(const [top,index] of [[-400,1],[-1200,3],[-2152,5],[-400,1],[200,0]]) {
    env.scrollTo(top);env.advance();env.advance();
    assert.equal(current().length,1);assert.equal(current()[0],env.lines[index]);
  }
  env.reduced.matches=true;env.change();assert.equal(current().length,0);
});

test('entry and exit effects reverse with scrolling and respect reduced motion',()=>{
  const env=setup();env.show(true);
  const move=top=>{env.scrollTo(top);env.advance();env.advance();};
  move(250);const entry={...env.properties};
  assert.ok(parseFloat(entry['--field-inset'])>0);
  assert.ok(parseFloat(entry['--field-text-y'])>0);
  move(-1000);assert.equal(env.properties['--field-inset'],'0px');
  assert.equal(env.properties['--field-blur'],'0.65px');
  move(-2402);assert.equal(env.properties['--field-inset'],entry['--field-inset']);
  assert.ok(parseFloat(env.properties['--field-text-y'])<0);
  move(-1000);assert.equal(env.properties['--field-inset'],'0px');
  env.reduced.matches=true;env.change();
  assert.equal(env.properties['--field-text-y'],'0px');
  assert.equal(env.properties['--field-radius'],'0px');
});
