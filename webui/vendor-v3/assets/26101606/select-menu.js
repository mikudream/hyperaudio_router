"use strict";
// The hidden selects remain the data source used by the audio/settings code.
// This component changes values and emits change; it never runs root commands.
window.HASelectMenus = (() => {
  const controls=new Map(),root=document.documentElement,app=document.querySelector('.app');
  const backdrop=document.createElement('div');
  backdrop.className='select-backdrop';backdrop.hidden=true;backdrop.setAttribute('aria-hidden','true');
  const popup=document.createElement('dialog');
  popup.className='select-popup';popup.id='ha-select-popup';
  const list=document.createElement('div');
  list.id='ha-select-options';list.setAttribute('role','listbox');popup.appendChild(list);
  document.body.append(backdrop,popup);
  let active=null,signature='',fallback=false,oldInert=false;
  const arrow='<svg class="icon select-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>';
  const check='<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m5 12 4 4L19 6"/></svg>';
  const choices=control=>Array.from(control.select.options).filter(option=>option.value!=='');
  function focus(element){if(!element)return;try{element.focus({preventScroll:true});}catch(_){element.focus();}}
  function close(restoreFocus=true){
    if(!active)return;
    const control=active;active=null;signature='';
    control.button.setAttribute('aria-expanded','false');
    root.classList.remove('select-open');backdrop.hidden=true;
    if(fallback&&app)app.inert=oldInert;
    if(popup.open){if(typeof popup.close==='function')popup.close();else popup.removeAttribute('open');}
    fallback=false;
    if(restoreFocus&&!document.hidden&&!control.button.disabled)focus(control.button);
  }
  function position(){
    if(!active)return;
    const vv=window.visualViewport,css=getComputedStyle(root);
    const inset=name=>Math.max(0,parseFloat(css.getPropertyValue('--ha-safe-'+name))||0);
    const width=vv&&vv.width||window.innerWidth||430,height=vv&&vv.height||window.innerHeight||820;
    const originX=vv&&vv.offsetLeft||0,originY=vv&&vv.offsetTop||0;
    const minX=originX+inset('left')+12,maxX=originX+width-inset('right')-12;
    const minY=originY+inset('top')+12,maxY=originY+height-inset('bottom')-12;
    const rect=active.button.getBoundingClientRect();
    const menuWidth=Math.max(1,Math.min(Math.max(rect.width,240),360,maxX-minX));
    popup.style.width=menuWidth+'px';
    popup.style.left=Math.max(minX,Math.min(rect.right-menuWidth,maxX-menuWidth))+'px';
    const top=Math.max(minY,Math.min(rect.top,maxY)),bottom=Math.max(minY,Math.min(rect.bottom,maxY));
    const above=Math.max(0,top-minY-8),below=Math.max(0,maxY-bottom-8);
    const natural=popup.scrollHeight||choices(active).length*60+12;
    const useBelow=below>=Math.min(natural,160)||below>=above;
    const room=Math.max(1,useBelow?below:above);
    popup.style.maxHeight=room+'px';
    popup.style.top=(useBelow?bottom+8:top-8-Math.min(natural,room))+'px';
  }
  function render(){
    if(!active)return;
    const control=active,options=choices(control);
    const next=JSON.stringify([control.select.value,options.map(o=>[o.value,o.textContent,o.disabled])]);
    if(next===signature)return;
    signature=next;list.textContent='';
    for(const option of options){
      const button=document.createElement('button');
      button.type='button';button.className='select-option';button.dataset.value=option.value;
      button.setAttribute('role','option');button.disabled=option.disabled;
      button.setAttribute('aria-selected',String(option.value===control.select.value));
      button.tabIndex=option.value===control.select.value?0:-1;
      const text=document.createElement('span');text.className='select-option-text';text.textContent=option.textContent;
      const icon=document.createElement('span');icon.className='select-option-check';icon.innerHTML=check;
      button.append(text,icon);
      button.addEventListener('click',()=>{
        if(active!==control||control.select.disabled||button.disabled)return;
        const changed=control.select.value!==option.value;
        control.select.value=option.value;close();refresh(control.select.id);
        if(changed)control.select.dispatchEvent(new Event('change',{bubbles:true}));
      });
      list.appendChild(button);
    }
    position();
  }
  function refresh(id){
    for(const [name,control] of controls){
      if(id&&id!==name)continue;
      const selected=control.select.selectedOptions[0];
      control.caption.textContent=selected?selected.textContent:'请选择';
      control.button.setAttribute('aria-label',control.label+'：'+control.caption.textContent);
      control.button.disabled=control.select.disabled||!choices(control).some(o=>!o.disabled);
      if(active===control){
        if(control.button.disabled){close(false);continue;}
        render();
        // The app's busy-state update also visits menu buttons.
        list.querySelectorAll('.select-option').forEach(button=>{
          const option=choices(control).find(o=>o.value===button.dataset.value);
          button.disabled=!option||option.disabled;
        });
      }
    }
  }
  function open(id){
    refresh(id);
    const control=controls.get(id);
    if(!control||control.button.disabled)return false;
    close(false);active=control;signature='';
    popup.setAttribute('aria-label',control.label);list.setAttribute('aria-label',control.label);
    control.button.setAttribute('aria-expanded','true');root.classList.add('select-open');
    fallback=typeof popup.showModal!=='function';
    if(!fallback){try{popup.showModal();}catch(_){fallback=true;}}
    if(fallback){popup.setAttribute('open','');backdrop.hidden=false;if(app){oldInert=app.inert;app.inert=true;}}
    render();position();
    const selected=list.querySelector('[aria-selected="true"]:not(:disabled)')||list.querySelector('.select-option:not(:disabled)');
    focus(selected);
    if(selected&&popup.clientHeight)popup.scrollTop=Math.max(0,selected.offsetTop-popup.clientHeight/2+selected.offsetHeight/2);
    return true;
  }
  document.querySelectorAll('select[data-select-label]').forEach(select=>{
    const button=document.createElement('button'),caption=document.createElement('span');
    button.type='button';button.id=select.id+'-trigger';
    button.className='select-trigger select-trigger-'+select.dataset.selectStyle;
    button.setAttribute('aria-haspopup','listbox');button.setAttribute('aria-expanded','false');button.setAttribute('aria-controls',list.id);
    caption.className='select-text';button.appendChild(caption);button.insertAdjacentHTML('beforeend',arrow);
    select.insertAdjacentElement('afterend',button);
    controls.set(select.id,{select,button,caption,label:select.dataset.selectLabel});
    button.addEventListener('click',()=>open(select.id));
    select.addEventListener('change',()=>refresh(select.id));
  });
  backdrop.addEventListener('click',()=>close());
  popup.addEventListener('click',event=>{
    if(event.target!==popup)return;
    const r=popup.getBoundingClientRect();
    if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)close();
  });
  popup.addEventListener('cancel',event=>{event.preventDefault();close();});
  popup.addEventListener('close',()=>{if(!popup.open)close();});
  document.addEventListener('keydown',event=>{
    if(!active)return;
    if(event.key==='Escape'){event.preventDefault();close();return;}
    if(event.key==='Tab'){close();return;}
    const options=Array.from(list.querySelectorAll('.select-option:not(:disabled)'));
    if(!options.length)return;
    let index=options.indexOf(document.activeElement);
    if(['ArrowDown','ArrowUp','Home','End'].includes(event.key)){
      event.preventDefault();
      if(event.key==='Home')index=0;
      else if(event.key==='End')index=options.length-1;
      else index=(Math.max(0,index)+(event.key==='ArrowDown'?1:-1)+options.length)%options.length;
      options.forEach((button,i)=>{button.tabIndex=i===index?0:-1;});focus(options[index]);
    }else if((event.key==='Enter'||event.key===' ')&&index>=0){event.preventDefault();options[index].click();}
  });
  window.addEventListener('resize',position);
  if(window.visualViewport){window.visualViewport.addEventListener('resize',position);window.visualViewport.addEventListener('scroll',position);}
  document.addEventListener('visibilitychange',()=>{if(document.hidden)close(false);});
  refresh();
  return {refresh,close,open};
})();
