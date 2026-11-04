"use strict";
// Local reading/navigation only. No root, mode-switch or audio bridge calls.
(() => {
 const data=window.HACreditsData,$=id=>document.getElementById(id);
 const dialog=$('credits-dialog'),body=$('credits-body'),back=$('credits-back'),dismiss=$('credits-close');
 const app=document.querySelector('.app'),root=document.documentElement;
 let stack=[],current=null,trigger=null,fallback=false,previousInert=false;
 const titles={contributors:'维护与制作',projects:'项目致谢',licenses:'开源许可',origin:'音频方案与来源',statement:'第三方声明'};
 const groups=[['设计与图标',['miuix','material']],['玻璃与交互',['liquid','haze','kernelsu']],['界面与标识参考',['miuix-vue','hyperisland','hyperceiler']]];
 function node(tag,text,cls){const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;}
 function focus(e){if(!e)return;try{e.focus({preventScroll:true});}catch(_){e.focus();}}
 function icon(kind){
  const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg'),path=document.createElementNS(ns,'path');
  svg.setAttribute('class','icon');svg.setAttribute('viewBox','0 0 24 24');svg.setAttribute('aria-hidden','true');
  path.setAttribute('d',kind==='external'?'M14 4h6v6m0-6L10 14M10 4H5a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-5':kind==='ai'?'m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5Z':'M7 3h7l4 4v14H6V3m8 0v5h4M9 12h6m-6 4h6');
  svg.appendChild(path);return svg;
 }
 function leading(text,kind){const e=node('span',kind?undefined:text,'credit-leading');e.setAttribute('aria-hidden','true');if(kind)e.appendChild(icon(kind));return e;}
 function heading(title,summary){
  $('credits-title').textContent=title;
  const e=node('div',undefined,'credits-heading'),large=node('h2',title,'credits-large-title');
  large.setAttribute('aria-hidden','true');e.appendChild(large);
  if(summary)e.appendChild(node('p',summary,'credits-intro'));body.appendChild(e);
 }
 function section(title){
  const section=node('section',undefined,'credits-section'),label=node('h3',title,'credit-section-title'),list=node('ul',undefined,'credit-group');
  label.id='credits-section-'+body.querySelectorAll('.credits-section').length;section.setAttribute('aria-labelledby',label.id);
  section.append(label,list);body.appendChild(section);return list;
 }
 function row(list,{name,detail,mark,kind,key,onClick,url}){
  const li=node('li'),e=node(onClick?'button':url?'a':'div',undefined,'credit-row');
  if(onClick){e.type='button';e.dataset.creditKey=key;e.addEventListener('click',()=>onClick(e));}
  if(url){e.href=url;e.target='_blank';e.rel='noopener noreferrer';e.setAttribute('aria-label',name+'，打开外部来源');}
  const copy=node('span',undefined,'credit-copy');copy.appendChild(node('b',name));if(detail)copy.appendChild(node('small',detail));
  e.append(leading(mark||Array.from(name)[0],kind),copy);
  if(onClick){const arrow=node('span',undefined,'chevron');arrow.setAttribute('aria-hidden','true');e.appendChild(arrow);}
  if(url)e.appendChild(icon('external'));
  li.appendChild(e);list.appendChild(li);return e;
 }
 function note(text){body.appendChild(node('p',text,'credit-note'));}
 function prose(paragraphs){const e=node('div',undefined,'credit-prose');for(const text of paragraphs)e.appendChild(node('p',text));body.appendChild(e);return e;}
 function link(text,url,cls='credit-source-link'){
  const e=node('a',undefined,cls);e.append(node('span',text),icon('external'));e.href=url;e.target='_blank';e.rel='noopener noreferrer';e.setAttribute('aria-label',text+'，打开外部来源');return e;
 }
 function titleFor(view){return titles[view.type]||(view.type==='project'?data.projects:data.licenses).find(x=>x.id===view.id)?.name||'关于';}
 function updateScroll(){
  const large=body.querySelector('.credits-large-title'),height=large&&large.offsetHeight||40;
  dialog.style.setProperty('--credits-collapse',String(Math.max(0,Math.min(1,(body.scrollTop-10)/height))));
  dialog.dataset.scrolled=String(body.scrollTop>0);
 }
 function render(scrollTop=0){
  body.replaceChildren();dialog.dataset.view=current.type;dismiss.hidden=stack.length===0;
  back.setAttribute('aria-label',stack.length?'返回'+titleFor(stack[stack.length-1].view):'返回关于');
  if(current.type==='contributors'){
   heading('维护与制作','感谢一起完善 HyperAudio Switch 的伙伴。');
   const people=section('本版维护');for(const person of data.maintainers)row(people,person);
   const assistance=section('AI 辅助');for(const item of data.assistance)row(assistance,{...item,kind:'ai'});
   note('上游音频方案作者，另列于“音频方案与来源”。');
  }else if(current.type==='projects'){
   heading('项目致谢','感谢为界面、交互和图标提供启发与基础的项目。');
   for(const [label,ids] of groups){const list=section(label);
    for(const id of ids){const project=data.projects.find(x=>x.id===id);row(list,{name:project.name,detail:project.short,key:'project:'+id,onClick:source=>go({type:'project',id},source)});}
   }
   note('点按项目可查看具体使用范围、来源和适用许可。');
  }else if(current.type==='project'){
   const project=data.projects.find(x=>x.id===current.id);heading(project.name,project.short);
   const identity=node('div',undefined,'credit-identity'),copy=node('div');copy.append(node('p',project.owner,'credit-owner'),node('p',project.scope,'credit-scope'));identity.append(leading(Array.from(project.name)[0]),copy);body.appendChild(identity);
   prose([project.text]);const actions=node('div',undefined,'credit-actions');actions.appendChild(link('项目主页',project.source,'credit-action'));
   if(project.licenseId){const button=node('button','查看许可','credit-action credit-action-primary');button.type='button';button.dataset.creditKey='project-license';button.addEventListener('click',()=>go({type:'license',id:project.licenseId},button));actions.appendChild(button);}
   body.appendChild(actions);if(project.extraSource)body.appendChild(link('Material Symbols 图标仓库',project.extraSource));
  }else if(current.type==='licenses'){
   heading('开源许可','随界面提供的代码与图标，保留原作者署名和许可原文。');
   const list=section('许可与使用范围');
   for(const item of data.licenses)row(list,{name:item.name,detail:item.license,kind:'license',key:'license:'+item.id,onClick:source=>go({type:'license',id:item.id},source)});
  }else if(current.type==='license'){
   const item=data.licenses.find(x=>x.id===current.id);heading(item.name,item.license);
   prose([item.copyright,item.usage]);body.appendChild(node('pre',item.text,'credit-license-text'));
  }else if(current.type==='origin'){
   heading('音频方案与来源','记录上游音频方案，感谢原作者的探索与整理。');
   for(const [label,items] of [['上游音频方案',data.origins]]){
    const list=section(label);for(const item of items)row(list,{name:item.name,detail:item.owner,url:item.source});
   }
   note('以上为来源署名与致谢，不表示原作者参与本版维护，或对本版作出认可。');
   const licenseSection=node('section',undefined,'credits-section');licenseSection.appendChild(node('h3','来源与授权','credit-section-title'));body.appendChild(licenseSection);
   const text=prose(['上游方案的署名予以保留。现有记录尚未确认上游对本版的明确分发授权，来源致谢不代替授权确认。']);licenseSection.appendChild(text);
  }else{
   heading('第三方声明','项目关系、来源记录与版权说明。');
   prose(['HyperAudio Switch 是独立维护的第三方模块，与小米、Google 及所列项目无官方隶属、合作或背书关系。','界面与交互参考、实际使用的代码及图标，已分别注明使用范围。第三方内容的版权归原作者，引用部分保留原作者署名与相应许可证。','项目名称仅用于说明来源。致谢不代表获得额外授权，也不授予相关商标、标识或其他内容的使用权。']);
  }
  body.scrollTop=scrollTop;updateScroll();
 }
 function cleanup(){
  if(fallback&&app)app.inert=previousInert;
  fallback=false;current=null;stack=[];root.classList.remove('credits-open');
  if(trigger&&trigger.isConnected&&!trigger.closest('[hidden]'))focus(trigger);trigger=null;
 }
 function close(){
  if(!dialog.open)return;
  if(typeof dialog.close==='function')dialog.close();else dialog.removeAttribute('open');cleanup();
 }
 function open(view,source){
  if(window.HASelectMenus)window.HASelectMenus.close();
  trigger=source||document.activeElement;stack=[];current=view;render();
  document.querySelector('.bottom-nav').dispatchEvent(new Event('ha:nav-reset'));
  if(!dialog.open){
   fallback=typeof dialog.showModal!=='function';
   if(!fallback){try{dialog.showModal();}catch(_){fallback=true;}}
   if(fallback){previousInert=app.inert;app.inert=true;dialog.setAttribute('open','');}
  }
  root.classList.add('credits-open');focus(back);
 }
 function go(view,source){stack.push({view:current,scrollTop:body.scrollTop,focusKey:source?.dataset.creditKey});current=view;render();focus(back);}
 function navigateBack(){
  if(!stack.length){close();return;}
  const saved=stack.pop();current=saved.view;render(saved.scrollTop);
  const previous=Array.from(body.querySelectorAll('[data-credit-key]')).find(x=>x.dataset.creditKey===saved.focusKey);focus(previous||back);
 }
 for(const [id,type] of [['btn-contributors','contributors'],['btn-projects','projects'],['btn-licenses','licenses'],['btn-audio-origin','origin'],['btn-third-party','statement']])$(id).addEventListener('click',event=>open({type},event.currentTarget));
 $('maintainer-count').textContent=data.maintainers.length+' 位';
 back.addEventListener('click',navigateBack);dismiss.addEventListener('click',close);
 body.addEventListener('scroll',updateScroll,{passive:true});
 dialog.addEventListener('cancel',event=>{event.preventDefault();navigateBack();});
 dialog.addEventListener('close',()=>{if(!dialog.open&&current)cleanup();});
 dialog.addEventListener('click',event=>{if(event.target!==dialog)return;const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)close();});
 document.addEventListener('keydown',event=>{
  if(!fallback||!dialog.open)return;
  if(event.key==='Escape'){event.preventDefault();navigateBack();}
  if(event.key==='Tab'){
   const items=Array.from(dialog.querySelectorAll('button,a[href]')).filter(e=>!e.hidden&&!e.disabled),first=items[0],last=items[items.length-1];
   if(event.shiftKey&&(document.activeElement===first||!dialog.contains(document.activeElement))){event.preventDefault();focus(last);}
   else if(!event.shiftKey&&(document.activeElement===last||!dialog.contains(document.activeElement))){event.preventDefault();focus(first);}
  }
 });
 window.addEventListener('ha:page',close);window.addEventListener('pagehide',close);
 window.HAAbout={close,openSection:type=>{if(Object.prototype.hasOwnProperty.call(titles,type))open({type});},openLicenses:()=>open({type:'licenses'}),openProject:id=>{if(data.projects.some(x=>x.id===id))open({type:'project',id});}};
})();
