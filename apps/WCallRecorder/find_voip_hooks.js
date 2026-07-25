// frida -U -n WeChat -l find_voip_hooks.js
// Run AFTER placing/receiving a call once (VoIP modules are lazy on 8.0.71).

function listInteresting() {
  const reClass = /VoIP|VOIP|MultiTalk|ILink|Ilink|Audio|Conf|Talk|Record|AUAudio|Device/i;
  const reMethod = /Record|Audio|PCM|Pcm|Buffer|Play|Render|Mic|Speaker|StartRecord|StopForVoIP|MultiTalk|Ilink|Input|Output|Frame|Sample/i;
  let n = 0;
  ObjC.enumerateLoadedClasses({
    onMatch(name) {
      if (!reClass.test(name)) return;
      const cls = ObjC.classes[name];
      if (!cls) return;
      const methods = cls.$ownMethods.filter(m => reMethod.test(m));
      if (methods.length) {
        console.log('\n[class] ' + name);
        methods.forEach(m => {
          try {
            const impl = cls[m];
            const types = impl ? impl.types : '?';
            console.log('  ' + m + '  types=' + types);
          } catch (e) {
            console.log('  ' + m);
          }
        });
        n++;
      }
    },
    onComplete() { console.log('\nDone. classes matched: ' + n); }
  });
}

function tryHookKnown() {
  const names = [
    'StartRecordAndPlayForVoIP',
    'StartRecordAndPlayForVoIPWithRoomID:roomKey:',
    'StopForVoIP',
    'StartRecordAndPlayForMuTalk',
    'StartRecordAndPlayForIlink:',
    'openAudioWindowWithContext:',
    'ilinkOpenWindowWithContact:msgWrap:isCaller:from:startInApp:isEarMode:isAudioMode:'
  ];
  for (const sel of names) {
    let found = false;
    for (const cname in ObjC.classes) {
      const cls = ObjC.classes[cname];
      if (cls && cls['- ' + sel]) {
        console.log('[found] -[' + cname + ' ' + sel + ']');
        Interceptor.attach(cls['- ' + sel].implementation, {
          onEnter() { console.log('[call] -[' + cname + ' ' + sel + ']'); }
        });
        found = true;
      }
    }
    if (!found) console.log('[miss] ' + sel);
  }
}

function scanPcmLike() {
  const re = /(pcm|audio.*data|mic|play.*data|record.*data|input.*buffer|output.*buffer)/i;
  let hits = 0;
  for (const cname in ObjC.classes) {
    if (!/audio|voip|talk|conf|device|ilink/i.test(cname)) continue;
    const cls = ObjC.classes[cname];
    if (!cls) continue;
    for (const m of cls.$ownMethods) {
      if (!re.test(m)) continue;
      const argc = (m.match(/:/g) || []).length;
      if (argc < 1 || argc > 3) continue;
      console.log('[pcm?] -[' + cname + ' ' + m.replace(/^- /, '') + ']');
      hits++;
    }
  }
  console.log('pcm-like hits: ' + hits);
  console.log('Fill WCRExtraAudioHooks() like:');
  console.log('  @[@"ClassName", @"selector:name:", @"mic"|"remote"]');
}

setTimeout(() => {
  listInteresting();
  tryHookKnown();
  scanPcmLike();
}, 1500);
