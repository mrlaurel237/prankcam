// PrankCam - lecture video avec reperes nommes + telecommande web.
// Le bandeau "LIVE PRANK" est dessine sur chaque image et ne peut pas etre desactive.
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <MediaToolbox/MediaToolbox.h>
#import <os/lock.h>

#define PC_DIR @"/var/tmp/PrankCam"   // mets tes videos ici
#define PC_WM  @"LIVE PRANK"
#define PC_PORT 8765
#define RING_N (1<<18)
#define RING_MASK (RING_N-1)

@interface PCEngine : NSObject {
  CVPixelBufferRef _last; CIImage *_wm; CGSize _wmSize; BOOL _serverUp;
  float *_ring; size_t _wp; double _rp; os_unfair_lock _lock;
  double _tapRate; UInt32 _tapCh; BOOL _tapNonInter;
}
@property (nonatomic) BOOL audioOn;               // son de la video (ON par defaut)
@property (nonatomic) BOOL enabled;               // OFF par defaut a chaque lancement
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItemVideoOutput *out;
@property (nonatomic, copy) NSString *current;
@property (nonatomic, strong) NSMutableDictionary *cues; // fichier -> {nom: secondes}
@property (nonatomic, strong) CIContext *ci;
+ (instancetype)shared;
- (void)startServer;
- (void)pushABL:(AudioBufferList *)abl frames:(UInt32)n;
- (void)tapRate:(double)r ch:(UInt32)c nonInter:(BOOL)ni;
- (void)flush;
- (CMSampleBufferRef)replace:(CMSampleBufferRef)sb CF_RETURNS_RETAINED;
- (void)replaceAudio:(CMSampleBufferRef)sb;
@end

static void tapInit(MTAudioProcessingTapRef t, void *ci, void **out) { *out = ci; }
static void tapFinalize(MTAudioProcessingTapRef t) {}
static void tapPrepare(MTAudioProcessingTapRef t, CMItemCount m, const AudioStreamBasicDescription *f) {
  [[PCEngine shared] tapRate:f->mSampleRate ch:f->mChannelsPerFrame nonInter:(f->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0];
}
static void tapUnprepare(MTAudioProcessingTapRef t) {}
static void tapProcess(MTAudioProcessingTapRef t, CMItemCount n, MTAudioProcessingTapFlags fl,
                       AudioBufferList *abl, CMItemCount *nOut, MTAudioProcessingTapFlags *flOut) {
  if (MTAudioProcessingTapGetSourceAudio(t, n, abl, flOut, NULL, nOut) != noErr) return;
  [[PCEngine shared] pushABL:abl frames:(UInt32)*nOut];
  for (UInt32 b = 0; b < abl->mNumberBuffers; b++) memset(abl->mBuffers[b].mData, 0, abl->mBuffers[b].mDataByteSize); // pas de son local
}

@implementation PCEngine
+ (instancetype)shared {
  static PCEngine *e; static dispatch_once_t o;
  dispatch_once(&o, ^{ e = [PCEngine new]; });
  return e;
}
- (instancetype)init {
  if ((self = [super init])) {
    _ci = [CIContext contextWithOptions:nil];
    _ring = (float *)calloc(RING_N, sizeof(float)); _lock = OS_UNFAIR_LOCK_INIT; _audioOn = YES;
    NSData *d = [NSData dataWithContentsOfFile:[PC_DIR stringByAppendingPathComponent:@"cues.json"]];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    _cues = [j isKindOfClass:NSMutableDictionary.class] ? j : [NSMutableDictionary new];
  }
  return self;
}
- (void)saveCues {
  NSData *d = [NSJSONSerialization dataWithJSONObject:_cues options:0 error:nil];
  [d writeToFile:[PC_DIR stringByAppendingPathComponent:@"cues.json"] atomically:YES];
}
- (void)tapRate:(double)r ch:(UInt32)c nonInter:(BOOL)ni { _tapRate = r; _tapCh = MAX(c, 1); _tapNonInter = ni; }
- (void)flush { os_unfair_lock_lock(&_lock); _rp = (double)_wp; os_unfair_lock_unlock(&_lock); }
- (void)pushABL:(AudioBufferList *)abl frames:(UInt32)n {
  os_unfair_lock_lock(&_lock);
  if ((double)_wp - _rp > RING_N - 4096) _rp = (double)_wp - RING_N / 2;
  for (UInt32 i = 0; i < n; i++) {
    float s = 0;
    if (_tapNonInter) {
      for (UInt32 c = 0; c < abl->mNumberBuffers; c++) s += ((float *)abl->mBuffers[c].mData)[i];
      s /= MAX(abl->mNumberBuffers, 1);
    } else {
      float *d = (float *)abl->mBuffers[0].mData;
      for (UInt32 c = 0; c < _tapCh; c++) s += d[i * _tapCh + c];
      s /= _tapCh;
    }
    _ring[(_wp++) & RING_MASK] = s;
  }
  os_unfair_lock_unlock(&_lock);
}
- (void)replaceAudio:(CMSampleBufferRef)sb {
  CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
  const AudioStreamBasicDescription *a = fd ? CMAudioFormatDescriptionGetStreamBasicDescription(fd) : NULL;
  CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
  if (!a || !bb || _tapRate <= 0) return;
  char *p = NULL; size_t len = 0, tot = 0;
  if (CMBlockBufferGetDataPointer(bb, 0, &len, &tot, &p) != kCMBlockBufferNoErr || len != tot) return;
  UInt32 fr = (UInt32)CMSampleBufferGetNumSamples(sb), ch = a->mChannelsPerFrame;
  BOOL flt = (a->mFormatFlags & kAudioFormatFlagIsFloat) != 0, planar = (a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  if (!((flt && a->mBitsPerChannel == 32) || (!flt && a->mBitsPerChannel == 16))) return;
  double ratio = _tapRate / a->mSampleRate;
  os_unfair_lock_lock(&_lock);
  BOOL have = ((double)_wp - _rp) >= fr * ratio + 2;
  for (UInt32 i = 0; i < fr; i++) {
    float s = have ? _ring[((size_t)(_rp + i * ratio)) & RING_MASK] : 0;
    for (UInt32 c = 0; c < ch; c++) {
      size_t idx = planar ? (size_t)c * fr + i : (size_t)i * ch + c;
      if (flt) ((float *)p)[idx] = s;
      else ((int16_t *)p)[idx] = (int16_t)(MAX(-1.f, MIN(1.f, s)) * 32767);
    }
  }
  if (have) _rp += fr * ratio;
  os_unfair_lock_unlock(&_lock);
}
- (void)load:(NSString *)f {
  NSString *p = [PC_DIR stringByAppendingPathComponent:f.lastPathComponent];
  if (![[NSFileManager defaultManager] fileExistsAtPath:p]) return;
  AVPlayerItem *it = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:p]];
  self.out = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:
              @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
  [it addOutput:self.out];
  AVAssetTrack *at = [[it.asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
  if (at) {
    AVMutableAudioMixInputParameters *ip = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:at];
    MTAudioProcessingTapCallbacks cb = {kMTAudioProcessingTapCallbacksVersion_0, (__bridge void *)self,
      tapInit, tapFinalize, tapPrepare, tapUnprepare, tapProcess};
    MTAudioProcessingTapRef tap = NULL;
    if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr) {
      ip.audioTapProcessor = tap; CFRelease(tap);
      AVMutableAudioMix *mix = [AVMutableAudioMix audioMix]; mix.inputParameters = @[ip]; it.audioMix = mix;
    }
  }
  [self flush];
  if (!self.player) { self.player = [AVPlayer new]; }
  [self.player replaceCurrentItemWithPlayerItem:it];
  self.current = f.lastPathComponent;
  [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
    object:it queue:nil usingBlock:^(NSNotification *n) {
      [self.player seekToTime:kCMTimeZero]; [self.player play]; }];
  [self.player play];
}
- (CIImage *)wmForSize:(CGSize)s {
  if (_wm && CGSizeEqualToSize(_wmSize, s)) return _wm;
  UIGraphicsBeginImageContextWithOptions(s, NO, 1);
  CGFloat fh = MAX(s.height * 0.028, 12);   // petit : ~3% de la hauteur
  NSShadow *sh = [NSShadow new]; sh.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
  sh.shadowOffset = CGSizeMake(0, 1); sh.shadowBlurRadius = 2;
  NSDictionary *a = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:fh],
                      NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55],
                      NSShadowAttributeName: sh};
  CGSize ts = [PC_WM sizeWithAttributes:a];
  [PC_WM drawAtPoint:CGPointMake((s.width - ts.width) / 2, s.height - ts.height - fh * 0.6) withAttributes:a];
  UIImage *im = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  _wm = [[CIImage alloc] initWithImage:im]; _wmSize = s;
  return _wm;
}
- (CMSampleBufferRef)replace:(CMSampleBufferRef)sb {
  if (!self.enabled) return NULL;
  CVImageBufferRef orig = CMSampleBufferGetImageBuffer(sb);
  if (!orig) { if (self.audioOn) [self replaceAudio:sb]; return NULL; }
  if (!self.out) return NULL;
  size_t W = CVPixelBufferGetWidth(orig), H = CVPixelBufferGetHeight(orig);
  CMTime t = [self.out itemTimeForHostTime:CACurrentMediaTime()];
  CVPixelBufferRef src = [self.out copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
  if (src) { if (_last) CVPixelBufferRelease(_last); _last = src; }
  if (!_last) return NULL;
  CIImage *img = [CIImage imageWithCVPixelBuffer:_last];
  // 1) bandeau obligatoire, dans le repere de la video (en bas de l'image)
  img = [[self wmForSize:img.extent.size] imageByCompositingOverImage:img];
  // 2) video portrait dans un buffer camera paysage -> rotation (si c'est de travers, inverse le signe)
  if (img.extent.size.width < img.extent.size.height && W > H) {
    img = [img imageByApplyingTransform:CGAffineTransformMakeRotation(-M_PI_2)];
  }
  img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-img.extent.origin.x, -img.extent.origin.y)];
  CGFloat s = MAX((CGFloat)W / img.extent.size.width, (CGFloat)H / img.extent.size.height);
  img = [img imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
  CGFloat dx = ((CGFloat)W - img.extent.size.width) / 2, dy = ((CGFloat)H - img.extent.size.height) / 2;
  img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
  CVPixelBufferRef dst = NULL;
  NSDictionary *at = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)at, &dst);
  if (!dst) return NULL;
  [self.ci render:img toCVPixelBuffer:dst bounds:CGRectMake(0, 0, W, H) colorSpace:nil];
  CMVideoFormatDescriptionRef fd = NULL;
  CMVideoFormatDescriptionCreateForImageBuffer(NULL, dst, &fd);
  CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(sb, 0, &ti);
  CMSampleBufferRef out = NULL;
  CMSampleBufferCreateReadyWithImageBuffer(NULL, dst, fd, &ti, &out);
  if (fd) CFRelease(fd);
  CVPixelBufferRelease(dst);
  return out;
}

// ---------- telecommande ----------
static NSString *const kHTML = @R"HTML(<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<style>body{font-family:-apple-system,sans-serif;background:#111;color:#fff;margin:12px}
button{font-size:20px;padding:16px;margin:4px;border:0;border-radius:12px;background:#2a6df4;color:#fff}
.off{background:#d33}.on{background:#2a2}.g{background:#444}.cue{min-width:46%}
select,input{font-size:18px;padding:10px;margin:4px;border-radius:8px;border:0}</style>
<h2>PrankCam</h2><div id=st></div>
<div><button class=on onclick="c('on')">ACTIVER</button><button class=off onclick="c('off')">DESACTIVER</button></div>
<div><button class=g onclick="c('audio_on')">Son video ON</button><button class=g onclick="c('audio_off')">Son video OFF (mon micro)</button></div>
<select id=v onchange="c('load?f='+this.value)"></select>
<div><button class=g onclick="c('seek?d=-5')">-5s</button><button class=g onclick="c('pause')">Pause</button>
<button class=g onclick="c('play')">Play</button><button class=g onclick="c('seek?d=5')">+5s</button></div>
<h3>Reperes</h3><div id=cues></div>
<div><input id=n placeholder="Nom du repere"><button class=g onclick="mark()">Marquer ici</button></div>
<script>
async function c(p){await fetch('/'+p);r()}
function mark(){let n=document.getElementById('n').value.trim();if(n)c('mark?n='+encodeURIComponent(n))}
async function r(){let s=await (await fetch('/state')).json();
document.getElementById('st').textContent=(s.enabled?'ACTIF':'INACTIF')+' - son '+(s.audio?'video':'micro')+' - '+(s.current||'aucune video')+' - '+s.time.toFixed(1)+'s';
let v=document.getElementById('v');if(v.options.length!=s.videos.length){v.innerHTML='<option value="">Choisir une video</option>'+s.videos.map(x=>'<option>'+x+'</option>').join('')}
document.getElementById('cues').innerHTML=Object.keys(s.cues).map(k=>'<button class=cue onclick="c(\'cue?n='+encodeURIComponent(k)+'\')">'+k+' ('+s.cues[k].toFixed(1)+'s)</button>').join('')}
r();setInterval(r,2000)
</script>)HTML";

- (NSData *)handle:(NSString *)path ctype:(NSString **)ct {
  NSURLComponents *uc = [NSURLComponents componentsWithString:[@"http://x" stringByAppendingString:path]];
  NSMutableDictionary *q = [NSMutableDictionary new];
  for (NSURLQueryItem *i in uc.queryItems) q[i.name] = i.value ?: @"";
  NSString *p = uc.path;
  *ct = @"application/json";
  if ([p isEqualToString:@"/"]) { *ct = @"text/html; charset=utf-8"; return [kHTML dataUsingEncoding:NSUTF8StringEncoding]; }
  if ([p isEqualToString:@"/on"]) self.enabled = YES;
  else if ([p isEqualToString:@"/off"]) self.enabled = NO;
  else if ([p isEqualToString:@"/audio_on"]) self.audioOn = YES;
  else if ([p isEqualToString:@"/audio_off"]) self.audioOn = NO;
  else if ([p isEqualToString:@"/play"]) [self.player play];
  else if ([p isEqualToString:@"/pause"]) [self.player pause];
  else if ([p isEqualToString:@"/load"]) [self load:q[@"f"] ?: @""];
  else if ([p isEqualToString:@"/seek"]) {
    double t = CMTimeGetSeconds(self.player.currentTime) + [q[@"d"] doubleValue];
    [self.player seekToTime:CMTimeMakeWithSeconds(MAX(t, 0), 600)]; [self flush];
  } else if ([p isEqualToString:@"/cue"] && self.current) {
    NSNumber *t = ((NSDictionary *)self.cues[self.current])[q[@"n"]];
    if (t) { [self.player seekToTime:CMTimeMakeWithSeconds(t.doubleValue, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero]; [self flush]; [self.player play]; }
  } else if ([p isEqualToString:@"/mark"] && self.current && [q[@"n"] length]) {
    NSMutableDictionary *m = self.cues[self.current] ?: [NSMutableDictionary new];
    double t = q[@"t"] ? [q[@"t"] doubleValue] : CMTimeGetSeconds(self.player.currentTime);
    m[q[@"n"]] = @(t); self.cues[self.current] = m; [self saveCues];
  } else if ([p isEqualToString:@"/del"] && self.current) {
    [self.cues[self.current] removeObjectForKey:q[@"n"]]; [self saveCues];
  }
  NSMutableArray *vids = [NSMutableArray new];
  for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:PC_DIR error:nil])
    if ([@[@"mp4", @"mov", @"m4v"] containsObject:f.pathExtension.lowercaseString]) [vids addObject:f];
  double curT = CMTimeGetSeconds(self.player.currentTime);
  if (curT != curT || curT > 1e12 || curT < -1e12) curT = 0;
  NSDictionary *s = @{@"enabled": @(self.enabled), @"audio": @(self.audioOn), @"current": self.current ?: [NSNull null], @"videos": vids,
    @"cues": self.cues[self.current ?: @""] ?: @{}, @"time": @(curT)};
  return [NSJSONSerialization dataWithJSONObject:s options:0 error:nil];
}
- (void)startServer {
  if (_serverUp) return; _serverUp = YES;
  [[NSFileManager defaultManager] createDirectoryAtPath:PC_DIR withIntermediateDirectories:YES attributes:nil error:nil];
  dispatch_async(dispatch_get_global_queue(0, 0), ^{
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_addr.s_addr = INADDR_ANY; a.sin_port = htons(PC_PORT);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 4) < 0) { close(s); self->_serverUp = NO; return; }
    for (;;) {
      int c = accept(s, NULL, NULL); if (c < 0) continue;
      char buf[2048]; memset(buf, 0, sizeof buf); read(c, buf, sizeof buf - 1);
      NSArray *parts = [[NSString stringWithUTF8String:buf] componentsSeparatedByString:@" "];
      NSString *path = parts.count > 1 ? parts[1] : @"/";
      __block NSData *body = nil; __block NSString *ct = nil;
      dispatch_sync(dispatch_get_main_queue(), ^{ body = [self handle:path ctype:&ct]; });
      NSString *h = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", ct, (unsigned long)body.length];
      write(c, h.UTF8String, strlen(h.UTF8String)); write(c, body.bytes, body.length); close(c);
    }
  });
}
@end

static NSMutableSet *patched;
static void PCPatch(Class cls) {
  SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
  Method m = class_getInstanceMethod(cls, sel);
  NSString *k = NSStringFromClass(cls);
  if (!m || [patched containsObject:k]) return;
  [patched addObject:k];
  IMP orig = method_getImplementation(m);
  IMP n = imp_implementationWithBlock(^(id me, AVCaptureOutput *o, CMSampleBufferRef sb, AVCaptureConnection *c) {
    CMSampleBufferRef rep = [[PCEngine shared] replace:sb];
    ((void (*)(id, SEL, id, CMSampleBufferRef, id))orig)(me, sel, o, rep ?: sb, c);
    if (rep) CFRelease(rep);
  });
  method_setImplementation(m, n);
}

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(dispatch_queue_t)q {
  if (d) { PCPatch([d class]); [[PCEngine shared] startServer]; }
  %orig;
}
%end

%hook AVCaptureAudioDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(dispatch_queue_t)q {
  if (d) { PCPatch([d class]); [[PCEngine shared] startServer]; }
  %orig;
}
%end

%ctor { patched = [NSMutableSet new]; }
