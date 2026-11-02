"use strict";
// One bottom-navigation frame: consume pointer input, then paint the optics.
// Unrelated page controls and all audio commands keep their own lifecycle.
window.HANavFrames=(()=>{
  const queues={input:new Map(),paint:new Map()};let frame=0,flushing=false;
  const pending=()=>queues.input.size||queues.paint.size;
  function flush(now){
    frame=0;flushing=true;
    try{
      for(const phase of ['input','paint']){
        const tasks=Array.from(queues[phase].values());queues[phase].clear();
        for(const task of tasks)task(now);
      }
    }finally{flushing=false;if(pending()&&!frame)frame=requestAnimationFrame(flush);}
  }
  function request(phase,key,task){queues[phase].set(key,task);if(!frame&&!flushing)frame=requestAnimationFrame(flush);}
  function cancel(phase,key){queues[phase].delete(key);if(frame&&!pending()){cancelAnimationFrame(frame);frame=0;}}
  function style(element,name,value){value=String(value);if(element.style.getPropertyValue(name)!==value)element.style.setProperty(name,value);}
  return {request,cancel,style};
})();
