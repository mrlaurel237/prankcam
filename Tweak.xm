// PrankCam Pro - lecture video avec reperes nommes, son, telecommande.
// Activation par ICONE FLOTTANTE (plus de combinaison de boutons) :
//   - tap sur l'icone        = activer / desactiver la camera de prank
//   - appui long sur l'icone = ouvrir la telecommande complete
//   - glisser                = deplacer l'icone (position memorisee)
// Mini-telecommande flottante : bouton "0" = retour au debut de la video (appui long = debut en pause), play/pause.
// Le bandeau "LIVE PRANK" est dessine sur chaque image et ne peut pas etre desactive.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <poll.h>
#import <unistd.h>
#import <MediaToolbox/MediaToolbox.h>
#import <AudioToolbox/AudioToolbox.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <os/lock.h>

static NSString *PCDirPath(void) {   // dossier prive de l'app courante (le meme que PrankCam : videos et reperes conserves)
  static NSString *p; static dispatch_once_t o;
  dispatch_once(&o, ^{
    p = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
          stringByAppendingPathComponent:@"PrankCam"] copy];
    [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
  });
  return p;
}
#define PC_DIR PCDirPath()
#define PC_WM  @"LIVE PRANK"
#define PC_PORT 8765
#define PC_ROT (M_PI_2)   // rotation video portrait -> buffer camera paysage (si l'image est encore a l'envers : mettre -M_PI_2)
#define RING_N (1<<18)
#define RING_MASK (RING_N-1)
#define PC_MAXF 8192      // taille max d'un bloc audio traite

static BOOL PCIsIOUnit(AudioUnit u) {   // unite d'entree micro (RemoteIO / VoiceProcessingIO)
  AudioComponentDescription d;
  AudioComponent c = AudioComponentInstanceGetComponent(u);
  if (!c || AudioComponentGetDescription(c, &d) != noErr) return NO;
  return d.componentType == kAudioUnitType_Output &&
         (d.componentSubType == kAudioUnitSubType_RemoteIO || d.componentSubType == kAudioUnitSubType_VoiceProcessingIO);
}
static BOOL PCBool(id v, BOOL def) { return [v isKindOfClass:NSNumber.class] ? [v boolValue] : def; }
static CGImagePropertyOrientation PCOrient(CGAffineTransform t) {   // rotation d'une piste video -> orientation
  if (t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0) return kCGImagePropertyOrientationRight;
  if (t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0) return kCGImagePropertyOrientationLeft;
  if (t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1) return kCGImagePropertyOrientationDown;
  return kCGImagePropertyOrientationUp;
}
static CIImage *PCMakeWM(CGSize s, BOOL top) {   // bandeau LIVE PRANK (toujours present)
  UIGraphicsBeginImageContextWithOptions(s, NO, 1);
  CGFloat fh = MAX(s.height * 0.028, 12);   // petit : ~3% de la hauteur
  NSShadow *sh = [NSShadow new]; sh.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
  sh.shadowOffset = CGSizeMake(0, 1); sh.shadowBlurRadius = 2;
  NSDictionary *a = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:fh],
                      NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55],
                      NSShadowAttributeName: sh};
  CGSize ts = [PC_WM sizeWithAttributes:a];
  [PC_WM drawAtPoint:CGPointMake((s.width - ts.width) / 2, top ? fh * 0.6 : s.height - ts.height - fh * 0.6) withAttributes:a];
  UIImage *im = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return [[CIImage alloc] initWithImage:im];
}
static CGColorSpaceRef PCSRGB(void) {
  static CGColorSpaceRef c; static dispatch_once_t o;
  dispatch_once(&o, ^{ c = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
  return c;
}
static void PCTag709(CVPixelBufferRef b) {
  CVBufferSetAttachment(b, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
}
static CIImage *PCSaturate(CIImage *img, float sat) {
  if (fabsf(sat - 1.f) <= 0.01f) return img;
  CIFilter *cc = [CIFilter filterWithName:@"CIColorControls"];
  [cc setValue:img forKey:kCIInputImageKey]; [cc setValue:@(sat) forKey:kCIInputSaturationKey];
  return cc.outputImage ?: img;
}
static void PCPreviewStart(void);
static void PCCaptureHooksOn(void);
static BOOL PCCaptureOn(void);
static float PCFloat(id v, float def) { return [v isKindOfClass:NSNumber.class] ? [v floatValue] : def; }
// gains audio lus depuis les threads audio (simples floats : pas de verrou necessaire)
static volatile float gMonGain  = 0.8f;   // volume d'ecoute de la video sur l'iPhone (0 = muet)
static volatile float gSendGain = 1.0f;   // volume de la video envoyee a la place du micro (0..2)
static volatile BOOL  gMixMic   = NO;     // ajouter ma voix (micro) au son de la video envoye
static NSArray<NSString *> *PCVideos(void) {
  NSMutableArray *vids = [NSMutableArray new];
  for (NSString *f in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:PC_DIR error:nil] sortedArrayUsingSelector:@selector(compare:)])
    if ([@[@"mp4", @"mov", @"m4v"] containsObject:f.pathExtension.lowercaseString]) [vids addObject:f];
  return vids;
}
static NSString *PCLocalIP(void) {   // adresse Wi-Fi de l'iPhone (pour la telecommande web)
  struct ifaddrs *ifs = NULL; NSString *ip = nil;
  if (getifaddrs(&ifs) != 0) return nil;
  for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
    if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
    if (strcmp(i->ifa_name, "en0") != 0 && strncmp(i->ifa_name, "bridge", 6) != 0) continue;
    char b[INET_ADDRSTRLEN];
    if (inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, b, sizeof b)) { ip = @(b); break; }
  }
  freeifaddrs(ifs);
  return ip;
}

@interface PCEngine : NSObject {
  CVPixelBufferRef _last; NSMutableDictionary *_wmCache; os_unfair_lock _wmLock, _frameLock; BOOL _serverUp;
  CGImagePropertyOrientation _srcOrient;
  float *_ring; size_t _wp; double _rp; os_unfair_lock _lock;
  double _tapRate; UInt32 _tapCh; BOOL _tapNonInter;
  id _endObs;
}
@property (nonatomic) BOOL audioOn;               // son de la video (ON par defaut)
@property (nonatomic) BOOL enabled;               // OFF par defaut a chaque lancement
@property (nonatomic) BOOL loop;                  // boucle a la fin (sinon : reste sur la derniere image)
@property (nonatomic) BOOL zeroOnActivate;        // repartir a 0 a chaque activation
@property (nonatomic) BOOL webOn;                 // telecommande web (OFF par defaut)
@property (nonatomic) BOOL monitorOn;             // entendre la video sur l'iPhone (ON par defaut)
@property (nonatomic) float monitorVol;           // volume d'ecoute 0..1
@property (nonatomic) float sendVol;              // volume de la video envoyee 0..2
@property (nonatomic) BOOL mixMic;                // envoyer video + ma voix
@property (nonatomic) float saturation;           // 1 = couleurs d'origine de la video
@property (atomic) NSUInteger frameGen;           // +1 a chaque nouvelle image de la video
@property (nonatomic, strong) NSMutableDictionary *prefs; // reglages persistants (settings.json)
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItemVideoOutput *out;
@property (nonatomic, copy) NSString *current;
@property (nonatomic, strong) NSMutableDictionary *cues; // fichier -> {nom: secondes}
@property (nonatomic, strong) CIContext *ci;
+ (instancetype)shared;
- (void)startServer;
- (void)savePrefs;
- (void)pushABL:(AudioBufferList *)abl frames:(UInt32)n;
- (void)tapRate:(double)r ch:(UInt32)c nonInter:(BOOL)ni;
- (void)flush;
- (BOOL)load:(NSString *)f;
- (void)setOn:(BOOL)on;
- (void)go;
- (void)applyAudio;
- (void)restart:(BOOL)play;
- (void)togglePlay;
- (void)seekBy:(double)d;
- (void)saveCues;
- (void)jumpCue:(NSString *)n;
- (void)markCue:(NSString *)n;
- (void)deleteCue:(NSString *)n;
- (void)deleteVideo:(NSString *)f;
- (CMSampleBufferRef)replace:(CMSampleBufferRef)sb CF_RETURNS_RETAINED;
- (CIImage *)grabFrame;
- (CIImage *)styled:(CIImage *)img upright:(BOOL)up;
- (CVPixelBufferRef)renderImage:(CIImage *)img maxSide:(CGFloat)m CF_RETURNS_RETAINED;
- (NSDictionary *)recordConfig;
- (void)replaceAudio:(CMSampleBufferRef)sb;
- (void)replaceAudioUnit:(AudioUnit)u abl:(AudioBufferList *)io frames:(UInt32)fr;
- (void)pull:(float *)out frames:(UInt32)fr ratio:(double)ratio;
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
  float g = gMonGain;                              // son local : volume d'ecoute (0 = muet)
  for (UInt32 b = 0; b < abl->mNumberBuffers; b++) {
    float *d = (float *)abl->mBuffers[b].mData; if (!d) continue;
    UInt32 n2 = abl->mBuffers[b].mDataByteSize / sizeof(float);
    if (g <= 0.001f) memset(d, 0, abl->mBuffers[b].mDataByteSize);
    else if (g < 0.999f) for (UInt32 i = 0; i < n2; i++) d[i] *= g;
  }
}

@implementation PCEngine
+ (instancetype)shared {
  static PCEngine *e; static dispatch_once_t o;
  dispatch_once(&o, ^{ e = [PCEngine new]; });
  return e;
}
- (instancetype)init {
  if ((self = [super init])) {
    _ci = [CIContext contextWithOptions:@{kCIContextHighQualityDownsample: @YES}];
    _ring = (float *)calloc(RING_N, sizeof(float)); _lock = OS_UNFAIR_LOCK_INIT;
    _wmLock = OS_UNFAIR_LOCK_INIT; _frameLock = OS_UNFAIR_LOCK_INIT; _wmCache = [NSMutableDictionary new];
    NSData *d = [NSData dataWithContentsOfFile:[PC_DIR stringByAppendingPathComponent:@"cues.json"]];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    _cues = [j isKindOfClass:NSMutableDictionary.class] ? j : [NSMutableDictionary new];
    NSData *pd = [NSData dataWithContentsOfFile:[PC_DIR stringByAppendingPathComponent:@"settings.json"]];
    id pj = pd ? [NSJSONSerialization JSONObjectWithData:pd options:NSJSONReadingMutableContainers error:nil] : nil;
    _prefs = [pj isKindOfClass:NSMutableDictionary.class] ? pj : [NSMutableDictionary new];
    _audioOn = PCBool(_prefs[@"audio"], YES);
    _loop = PCBool(_prefs[@"loop"], YES);
    _zeroOnActivate = PCBool(_prefs[@"zero"], YES);
    _webOn = PCBool(_prefs[@"web"], NO);
    _monitorOn = PCBool(_prefs[@"mon"], YES);
    _monitorVol = MAX(0.f, MIN(1.f, PCFloat(_prefs[@"mon_vol"], 0.8f)));
    _sendVol = MAX(0.f, MIN(2.f, PCFloat(_prefs[@"send_vol"], 1.0f)));
    _mixMic = PCBool(_prefs[@"mix"], NO);
    _saturation = MAX(0.f, MIN(1.5f, PCFloat(_prefs[@"sat"], 1.0f)));
    [self applyAudio];
  }
  return self;
}
- (void)savePrefs {
  _prefs[@"audio"] = @(_audioOn); _prefs[@"loop"] = @(_loop);
  _prefs[@"zero"] = @(_zeroOnActivate); _prefs[@"web"] = @(_webOn);
  _prefs[@"mon"] = @(_monitorOn); _prefs[@"mon_vol"] = @(_monitorVol); _prefs[@"send_vol"] = @(_sendVol);
  _prefs[@"mix"] = @(_mixMic); _prefs[@"sat"] = @(_saturation);
  [self applyAudio];
  NSData *d = [NSJSONSerialization dataWithJSONObject:_prefs options:0 error:nil];
  [d writeToFile:[PC_DIR stringByAppendingPathComponent:@"settings.json"] atomically:YES];
}
- (void)saveCues {
  NSData *d = [NSJSONSerialization dataWithJSONObject:_cues options:0 error:nil];
  [d writeToFile:[PC_DIR stringByAppendingPathComponent:@"cues.json"] atomically:YES];
}
- (void)applyAudio {
  gMonGain = self.monitorOn ? self.monitorVol : 0.f;
  gSendGain = self.sendVol; gMixMic = self.mixMic;
}
// lecture + son audible tout de suite : si l'app a mis le son dans l'ecouteur (appel) on bascule sur le haut-parleur,
// et si la session est "ambiante" (coupee par le bouton silence) on la passe en lecture.
- (void)go {
  if (self.monitorOn && self.monitorVol > 0.001f) {
    AVAudioSession *as = [AVAudioSession sharedInstance];
    NSString *cat = as.category;
    if ([cat isEqualToString:AVAudioSessionCategoryAmbient] || [cat isEqualToString:AVAudioSessionCategorySoloAmbient]) {
      [as setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
      [as setActive:YES error:nil];
    } else if ([cat isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
      for (AVAudioSessionPortDescription *o in as.currentRoute.outputs)
        if ([o.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) { [as overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil]; break; }
    }
  }
  [self.player play];
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
// preleve fr echantillons dans le tampon (reechantillonnes par interpolation lineaire) ; silence si pas assez de donnees.
// La latence est plafonnee (~0,3 s) pour que le son reste cale sur l'image.
- (void)pull:(float *)out frames:(UInt32)fr ratio:(double)ratio {
  os_unfair_lock_lock(&_lock);
  double rate = _tapRate > 0 ? _tapRate : 48000;
  if ((double)_wp - _rp > rate * 0.3) _rp = (double)_wp - rate * 0.12;
  BOOL have = ((double)_wp - _rp) >= fr * ratio + 2;
  if (have) {
    for (UInt32 i = 0; i < fr; i++) {
      double pos = _rp + i * ratio; size_t i0 = (size_t)pos; float f = (float)(pos - (double)i0);
      float a = _ring[i0 & RING_MASK], b = _ring[(i0 + 1) & RING_MASK];
      out[i] = a + (b - a) * f;
    }
    _rp += fr * ratio;
  } else memset(out, 0, fr * sizeof(float));      // rien a envoyer : silence (jamais le micro)
  os_unfair_lock_unlock(&_lock);
}
- (void)replaceAudio:(CMSampleBufferRef)sb {       // chemin AVCaptureAudioDataOutput
  CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
  const AudioStreamBasicDescription *a = fd ? CMAudioFormatDescriptionGetStreamBasicDescription(fd) : NULL;
  CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
  if (!a || !bb || _tapRate <= 0) return;
  char *p = NULL; size_t len = 0, tot = 0;
  if (CMBlockBufferGetDataPointer(bb, 0, &len, &tot, &p) != kCMBlockBufferNoErr || len != tot) return;
  UInt32 fr = (UInt32)CMSampleBufferGetNumSamples(sb), ch = a->mChannelsPerFrame;
  BOOL flt = (a->mFormatFlags & kAudioFormatFlagIsFloat) != 0, planar = (a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  if (!((flt && a->mBitsPerChannel == 32) || (!flt && a->mBitsPerChannel == 16))) return;
  if (!fr || fr > PC_MAXF || !ch) return;
  float tmp[PC_MAXF];
  [self pull:tmp frames:fr ratio:_tapRate / a->mSampleRate];
  float sg = gSendGain; BOOL mix = gMixMic;
  for (UInt32 i = 0; i < fr; i++) {
    float v = tmp[i] * sg;
    for (UInt32 c = 0; c < ch; c++) {
      size_t idx = planar ? (size_t)c * fr + i : (size_t)i * ch + c;
      float s = v;
      if (mix) s += flt ? ((float *)p)[idx] : ((int16_t *)p)[idx] / 32768.f;   // + ma voix
      s = MAX(-1.f, MIN(1.f, s));
      if (flt) ((float *)p)[idx] = s;
      else ((int16_t *)p)[idx] = (int16_t)(s * 32767);
    }
  }
}
- (void)replaceAudioUnit:(AudioUnit)u abl:(AudioBufferList *)io frames:(UInt32)fr {   // chemin AudioUnit (WhatsApp, Messenger, appels WebRTC...)
  if (!self.enabled || !self.audioOn || _tapRate <= 0) return;
  if (!io || !io->mNumberBuffers || !fr || fr > PC_MAXF || !io->mBuffers[0].mData) return;
  if (!PCIsIOUnit(u)) return;
  static AudioUnit cu; static Float64 crate;
  if (u != cu) {                                   // frequence d'echantillonnage du micro de cette unite
    AudioStreamBasicDescription d; UInt32 sz = sizeof d;
    if (AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &d, &sz) != noErr || d.mSampleRate <= 0) return;
    crate = d.mSampleRate; cu = u;
  }
  UInt32 ch0 = io->mBuffers[0].mNumberChannels ?: 1;
  UInt32 bps = io->mBuffers[0].mDataByteSize / fr / ch0;
  if (bps != 2 && bps != 4) return;                // int16 ou float32 uniquement
  float tmp[PC_MAXF];
  [self pull:tmp frames:fr ratio:_tapRate / crate];
  float sg = gSendGain; BOOL mix = gMixMic;
  for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
    AudioBuffer *ab = &io->mBuffers[b];
    UInt32 ch = ab->mNumberChannels ?: 1;
    if (!ab->mData || (size_t)fr * ch * bps > ab->mDataByteSize) continue;
    for (UInt32 i = 0; i < fr; i++) {
      float v = tmp[i] * sg;
      for (UInt32 c = 0; c < ch; c++) {
        size_t k = (size_t)i * ch + c;
        float s = v;
        if (mix) s += bps == 4 ? ((float *)ab->mData)[k] : ((int16_t *)ab->mData)[k] / 32768.f;   // + ma voix
        s = MAX(-1.f, MIN(1.f, s));
        if (bps == 4) ((float *)ab->mData)[k] = s;
        else ((int16_t *)ab->mData)[k] = (int16_t)(s * 32767);
      }
    }
  }
}
// ----- commandes de lecture -----
- (void)setOn:(BOOL)on {                        // activation : icone flottante, panneau ou telecommande web
  if (on) PCPreviewStart();
  if (on && !self.enabled) {
    if (self.zeroOnActivate) [self restart:YES];
    else [self go];
  } else if (!on && self.enabled) {
    [self.player pause];                        // la video attend ici (ou repart a 0 a la prochaine activation)
  }
  self.enabled = on;
}
- (void)restart:(BOOL)play {                    // bouton "0" : retour immediat au debut de la video
  if (!self.player.currentItem) return;
  [self.player pause];
  [self flush];
  __weak PCEngine *ws = self;
  [self.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL fin) {
    dispatch_async(dispatch_get_main_queue(), ^{
      PCEngine *s = ws; if (!s) return;
      [s flush];
      if (play) [s go];
    });
  }];
}
- (void)togglePlay {
  if (!self.player.currentItem) return;
  if (self.player.rate > 0) [self.player pause]; else [self go];
}
- (void)seekBy:(double)d {
  if (!self.player.currentItem) return;
  double t = CMTimeGetSeconds(self.player.currentTime) + d; if (!(t > 0)) t = 0;
  [self.player seekToTime:CMTimeMakeWithSeconds(t, 600)]; [self flush];
}
- (void)jumpCue:(NSString *)n {
  NSNumber *t = ((NSDictionary *)self.cues[self.current ?: @""])[n];
  if (![t isKindOfClass:NSNumber.class] || !self.player) return;
  [self.player seekToTime:CMTimeMakeWithSeconds(t.doubleValue, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
  [self flush]; [self go];
}
- (void)markCue:(NSString *)n {
  if (!self.current || !n.length) return;
  NSMutableDictionary *m = self.cues[self.current] ?: [NSMutableDictionary new];
  double t = CMTimeGetSeconds(self.player.currentTime); if (!(t > 0)) t = 0;
  m[n] = @(t); self.cues[self.current] = m; [self saveCues];
}
- (void)deleteCue:(NSString *)n {
  if (!self.current || !n) return;
  [(NSMutableDictionary *)self.cues[self.current] removeObjectForKey:n]; [self saveCues];
}
- (void)deleteVideo:(NSString *)f {              // supprime une video chargee (fichier + reperes)
  NSString *name = f.lastPathComponent;
  if (!name.length || ![PCVideos() containsObject:name]) return;   // uniquement les videos du dossier PrankCam
  if ([name isEqualToString:self.current]) {
    self.enabled = NO;                              // plus rien a injecter
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    if (_endObs) { [[NSNotificationCenter defaultCenter] removeObserver:_endObs]; _endObs = nil; }
    self.out = nil; self.current = nil;
    [self flush];
    [self.prefs removeObjectForKey:@"last"];
  }
  [[NSFileManager defaultManager] removeItemAtPath:[PC_DIR stringByAppendingPathComponent:name] error:nil];
  [self.cues removeObjectForKey:name]; [self saveCues]; [self savePrefs];
}
- (BOOL)load:(NSString *)f {
  NSString *name = f.lastPathComponent;
  if (!name.length) return NO;
  NSString *p = [PC_DIR stringByAppendingPathComponent:name];
  if (![[NSFileManager defaultManager] fileExistsAtPath:p]) return NO;
  AVPlayerItem *it = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:p]];
  AVAssetTrack *vt = [[it.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  self.out = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:
              @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}}];
  [it addOutput:self.out];
  _srcOrient = vt ? PCOrient(vt.preferredTransform) : kCGImagePropertyOrientationUp;
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
  self.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
  [self.player replaceCurrentItemWithPlayerItem:it];
  self.current = name;
  if (_endObs) [[NSNotificationCenter defaultCenter] removeObserver:_endObs];
  __weak PCEngine *ws = self;
  _endObs = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
    object:it queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
      PCEngine *s = ws; if (!s || !s.loop) return;   // sans boucle : reste fige sur la derniere image
      [s.player seekToTime:kCMTimeZero]; [s go]; }];
  self.prefs[@"last"] = name; [self savePrefs];
  if (self.enabled) [self go]; else [self.player pause];   // inactif : la video attend au debut
  return YES;
}
- (CIImage *)wmForSize:(CGSize)s {          // cache par taille (camera, apercu, photo...) ; appele depuis plusieurs threads
  BOOL top = PCBool(_prefs[@"wm_top"], NO);
  NSString *k = [NSString stringWithFormat:@"%.0fx%.0f-%d", s.width, s.height, top];
  os_unfair_lock_lock(&_wmLock);
  CIImage *w = _wmCache[k];
  os_unfair_lock_unlock(&_wmLock);
  if (w) return w;
  w = PCMakeWM(s, top);
  os_unfair_lock_lock(&_wmLock);
  if (_wmCache.count > 8) [_wmCache removeAllObjects];
  _wmCache[k] = w;
  os_unfair_lock_unlock(&_wmLock);
  return w;
}
- (CIImage *)grabFrame {                     // derniere image de la video (partagee : camera, apercu, photos)
  os_unfair_lock_lock(&_frameLock);
  AVPlayerItemVideoOutput *o = self.out;
  if (o) {
    CMTime t = [o itemTimeForHostTime:CACurrentMediaTime()];
    CVPixelBufferRef src = [o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
    if (src) { if (_last) CVPixelBufferRelease(_last); _last = src; self.frameGen++; }
  }
  CIImage *img = _last ? [CIImage imageWithCVPixelBuffer:_last] : nil;
  os_unfair_lock_unlock(&_frameLock);
  return img;
}
- (CIImage *)styled:(CIImage *)img upright:(BOOL)up {   // saturation + bandeau ; up = remise a l'endroit (apercu, photo)
  if (!img) return nil;
  if (up && _srcOrient != kCGImagePropertyOrientationUp) img = [img imageByApplyingCGOrientation:_srcOrient];
  img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-img.extent.origin.x, -img.extent.origin.y)];
  img = PCSaturate(img, self.saturation);
  return [[self wmForSize:img.extent.size] imageByCompositingOverImage:img];
}
- (CVPixelBufferRef)renderImage:(CIImage *)img maxSide:(CGFloat)m {
  if (!img) return NULL;
  CGSize sz = img.extent.size;
  CGFloat k = (m > 0 && MAX(sz.width, sz.height) > m) ? m / MAX(sz.width, sz.height) : 1;
  if (k < 1) img = [img imageByApplyingTransform:CGAffineTransformMakeScale(k, k)];
  size_t W = (size_t)lround(sz.width * k), H = (size_t)lround(sz.height * k);
  if (!W || !H) return NULL;
  CVPixelBufferRef dst = NULL;
  NSDictionary *at = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)at, &dst);
  if (!dst) return NULL;
  [self.ci render:img toCVPixelBuffer:dst bounds:CGRectMake(0, 0, W, H) colorSpace:PCSRGB()];
  return dst;
}
- (NSDictionary *)recordConfig {             // reglages figes au debut d'un enregistrement video
  if (!self.enabled || !self.current) return nil;
  double t = CMTimeGetSeconds(self.player.currentTime); if (!(t > 0)) t = 0;
  return @{@"path": [PC_DIR stringByAppendingPathComponent:self.current], @"start": @(t), @"audio": @(self.audioOn),
           @"send": @(self.sendVol), @"mix": @(self.mixMic), @"sat": @(self.saturation), @"top": @(PCBool(_prefs[@"wm_top"], NO))};
}
- (CMSampleBufferRef)replace:(CMSampleBufferRef)sb {
  if (!self.enabled) return NULL;
  CVImageBufferRef orig = CMSampleBufferGetImageBuffer(sb);
  if (!orig) { if (self.audioOn) [self replaceAudio:sb]; return NULL; }
  if (!self.out) return NULL;
  size_t W = CVPixelBufferGetWidth(orig), H = CVPixelBufferGetHeight(orig);
  // 1) saturation + bandeau obligatoire, dans le repere de la video (en bas de l'image)
  CIImage *img = [self styled:[self grabFrame] upright:NO];
  if (!img) return NULL;
  // 2) video portrait dans un buffer camera paysage -> rotation (si c'est de travers, inverse le signe)
  if (img.extent.size.width < img.extent.size.height && W > H) {
    img = [img imageByApplyingTransform:CGAffineTransformMakeRotation(PC_ROT)];
  }
  img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-img.extent.origin.x, -img.extent.origin.y)];
  CGFloat s = MAX((CGFloat)W / img.extent.size.width, (CGFloat)H / img.extent.size.height);
  if (fabs(s - 1.0) > 0.001) {                    // mise a l'echelle Lanczos : plus nette que le simple etirement
    CIFilter *lz = [CIFilter filterWithName:@"CILanczosScaleTransform"];
    [lz setValue:img forKey:kCIInputImageKey];
    [lz setValue:@(s) forKey:kCIInputScaleKey];
    [lz setValue:@1.0 forKey:kCIInputAspectRatioKey];
    img = lz.outputImage ?: [img imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
  }
  CGFloat dx = ((CGFloat)W - img.extent.size.width) / 2, dy = ((CGFloat)H - img.extent.size.height) / 2;
  img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
  CIFilter *sh = [CIFilter filterWithName:@"CISharpenLuminance"];   // legere accentuation : compense le flou apres reduction
  [sh setValue:img forKey:kCIInputImageKey]; [sh setValue:@0.4 forKey:kCIInputSharpnessKey];
  img = sh.outputImage ?: img;
  // L'image envoyee doit avoir EXACTEMENT le format de la vraie camera (en appel : YUV 420 bi-planaire).
  // Sinon elle s'affiche chez moi mais l'encodeur de l'appel la rejette et l'autre ne voit que la photo de profil.
  OSType fmt = CVPixelBufferGetPixelFormatType(orig);
  CVPixelBufferRef dst = NULL;
  NSDictionary *at = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  CVPixelBufferCreate(NULL, W, H, fmt, (__bridge CFDictionaryRef)at, &dst);
  if (!dst) {                                      // format exotique : BGRA comme avant
    fmt = kCVPixelFormatType_32BGRA;
    CVPixelBufferCreate(NULL, W, H, fmt, (__bridge CFDictionaryRef)at, &dst);
  }
  if (!dst) return NULL;
  CVBufferPropagateAttachments(orig, dst);        // memes infos couleur / matrice YUV que la camera
  // avant : colorSpace:nil = pas de gestion des couleurs -> l'image sortait en valeurs lineaires
  // (plus sombre, plus contrastee, couleurs trop saturees). On rend en sRGB.
  [self.ci render:img toCVPixelBuffer:dst bounds:CGRectMake(0, 0, W, H) colorSpace:PCSRGB()];
  CMVideoFormatDescriptionRef fd = NULL;
  CMVideoFormatDescriptionCreateForImageBuffer(NULL, dst, &fd);
  CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(sb, 0, &ti);
  CMSampleBufferRef out = NULL;
  CMSampleBufferCreateReadyWithImageBuffer(NULL, dst, fd, &ti, &out);
  if (fd) CFRelease(fd);
  CVPixelBufferRelease(dst);
  return out;
}

// ---------- telecommande web (depuis un autre telephone sur le meme Wi-Fi) ----------
static NSString *const kHTML = @R"HTML(<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<style>body{font-family:-apple-system,sans-serif;background:#111;color:#fff;margin:12px}
button{font-size:20px;padding:16px;margin:4px;border:0;border-radius:12px;background:#2a6df4;color:#fff}
.off{background:#d33}.on{background:#2a2}.g{background:#444}.cue{min-width:46%}.big{font-size:30px;min-width:46%;padding:22px}
#tg{width:96%}select,input{font-size:18px;padding:10px;margin:4px;border-radius:8px;border:0}</style>
<h2>PrankCam Pro</h2><div id=st></div>
<div><button id=tg class=off onclick="c('toggle')">...</button></div>
<div><button class=big onclick="c('zero')">&#9198; 0</button><button class="big g" onclick="c('playpause')">&#9199;</button></div>
<div><button class=g onclick="c('seek?d=-5')">-5s</button><button class=g onclick="c('ready')">0 + pause</button><button class=g onclick="c('seek?d=5')">+5s</button></div>
<div><button class=g onclick="c('audio_on')">Son video</button><button class=g onclick="c('audio_off')">Mon micro</button></div>
<div><button class=g onclick="c('loop_on')">Boucle ON</button><button class=g onclick="c('loop_off')">Boucle OFF</button></div>
<select id=v onchange="if(this.value)c('load?f='+encodeURIComponent(this.value))"></select>
<button class=g onclick="let f=document.getElementById('v').value;if(f&&confirm('Supprimer cette video ?'))c('delvideo?f='+encodeURIComponent(f))">Supprimer la video</button>
<h3>Reperes</h3><div id=cues></div>
<div><input id=n placeholder="Nom du repere"><button class=g onclick="mark()">Marquer ici</button></div>
<script>
async function c(p){await fetch('/'+p);r()}
function mark(){let n=document.getElementById('n').value.trim();if(n)c('mark?n='+encodeURIComponent(n))}
function esc(x){return String(x).replace(/[&<>"']/g,m=>'&#'+m.charCodeAt(0)+';')}
async function r(){let s=await (await fetch('/state')).json();
let tg=document.getElementById('tg');tg.className=s.enabled?'on':'off';tg.textContent=s.enabled?'ACTIF (toucher pour couper)':'INACTIF (toucher pour activer)';
document.getElementById('st').textContent=(s.playing?'lecture':'pause')+' - son '+(s.audio?'video':'micro')+' - boucle '+(s.loop?'ON':'OFF')+' - '+(s.current||'aucune video')+' - '+s.time.toFixed(1)+'s / '+s.dur.toFixed(1)+'s';
let v=document.getElementById('v');if(v.options.length!=s.videos.length+1){v.innerHTML='<option value="">Choisir une video</option>'+s.videos.map(x=>'<option value="'+esc(x)+'">'+esc(x)+'</option>').join('')}
document.getElementById('cues').innerHTML=Object.keys(s.cues).map(k=>'<button class=cue data-n="'+esc(k)+'" onclick="c(\'cue?n=\'+encodeURIComponent(this.dataset.n))">'+esc(k)+' ('+s.cues[k].toFixed(1)+'s)</button>').join('')}
r();setInterval(r,1500)
</script>)HTML";

- (NSData *)handle:(NSString *)path ctype:(NSString **)ct status:(int *)code {
  *ct = @"application/json"; *code = 200;
  if (!self.webOn) { *code = 403; *ct = @"text/plain; charset=utf-8"; return [@"Telecommande web desactivee dans PrankCam Pro" dataUsingEncoding:NSUTF8StringEncoding]; }
  NSURLComponents *uc = [NSURLComponents componentsWithString:[@"http://x" stringByAppendingString:path]];
  NSMutableDictionary *q = [NSMutableDictionary new];
  for (NSURLQueryItem *i in uc.queryItems) q[i.name] = i.value ?: @"";
  NSString *p = uc.path ?: @"/";
  if ([p isEqualToString:@"/"]) { *ct = @"text/html; charset=utf-8"; return [kHTML dataUsingEncoding:NSUTF8StringEncoding]; }
  if ([p isEqualToString:@"/on"]) [self setOn:YES];
  else if ([p isEqualToString:@"/off"]) [self setOn:NO];
  else if ([p isEqualToString:@"/toggle"]) [self setOn:!self.enabled];
  else if ([p isEqualToString:@"/zero"]) [self restart:YES];
  else if ([p isEqualToString:@"/ready"]) [self restart:NO];
  else if ([p isEqualToString:@"/playpause"]) [self togglePlay];
  else if ([p isEqualToString:@"/play"]) [self go];
  else if ([p isEqualToString:@"/pause"]) [self.player pause];
  else if ([p isEqualToString:@"/audio_on"]) { self.audioOn = YES; [self savePrefs]; }
  else if ([p isEqualToString:@"/audio_off"]) { self.audioOn = NO; [self savePrefs]; }
  else if ([p isEqualToString:@"/loop_on"]) { self.loop = YES; [self savePrefs]; }
  else if ([p isEqualToString:@"/loop_off"]) { self.loop = NO; [self savePrefs]; }
  else if ([p isEqualToString:@"/load"]) [self load:q[@"f"] ?: @""];
  else if ([p isEqualToString:@"/delvideo"]) [self deleteVideo:q[@"f"] ?: @""];
  else if ([p isEqualToString:@"/seek"]) [self seekBy:[q[@"d"] doubleValue]];
  else if ([p isEqualToString:@"/cue"]) [self jumpCue:q[@"n"] ?: @""];
  else if ([p isEqualToString:@"/mark"] && self.current && [q[@"n"] length]) {
    NSMutableDictionary *m = self.cues[self.current] ?: [NSMutableDictionary new];
    double t = q[@"t"] ? [q[@"t"] doubleValue] : CMTimeGetSeconds(self.player.currentTime);
    if (!(t > 0)) t = 0;
    m[q[@"n"]] = @(t); self.cues[self.current] = m; [self saveCues];
  } else if ([p isEqualToString:@"/del"]) [self deleteCue:q[@"n"]];
  double curT = CMTimeGetSeconds(self.player.currentTime);
  if (curT != curT || curT > 1e12 || curT < -1e12) curT = 0;
  double dur = CMTimeGetSeconds(self.player.currentItem.duration);
  if (dur != dur || dur > 1e12 || dur < 0) dur = 0;
  NSDictionary *s = @{@"enabled": @(self.enabled), @"audio": @(self.audioOn), @"loop": @(self.loop),
    @"playing": @(self.player.rate > 0), @"current": self.current ?: [NSNull null], @"videos": PCVideos(),
    @"cues": self.cues[self.current ?: @""] ?: @{}, @"time": @(curT), @"dur": @(dur)};
  return [NSJSONSerialization dataWithJSONObject:s options:0 error:nil];
}
- (void)startServer {                            // demarre une seule fois ; quand c'est desactive, tout est refuse (403)
  if (_serverUp) return; _serverUp = YES;
  dispatch_async(dispatch_get_global_queue(0, 0), ^{
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    if (s < 0) { dispatch_async(dispatch_get_main_queue(), ^{ self->_serverUp = NO; }); return; }
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_addr.s_addr = INADDR_ANY; a.sin_port = htons(PC_PORT);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 4) < 0) {
      close(s); dispatch_async(dispatch_get_main_queue(), ^{ self->_serverUp = NO; }); return;
    }
    for (;;) {
      int c = accept(s, NULL, NULL); if (c < 0) continue;
      setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);   // un client qui coupe ne doit pas tuer l'app
      struct timeval tv = {2, 0};
      setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);       // un client muet ne bloque pas la telecommande
      setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
      char buf[2048]; memset(buf, 0, sizeof buf);
      if (read(c, buf, sizeof buf - 1) <= 0) { close(c); continue; }
      NSString *req = [[NSString alloc] initWithBytes:buf length:strnlen(buf, sizeof buf) encoding:NSUTF8StringEncoding];
      NSArray *parts = [req componentsSeparatedByString:@" "];
      NSString *path = parts.count > 1 ? parts[1] : @"/";
      __block NSData *body = nil; __block NSString *ct = nil; __block int code = 200;
      dispatch_sync(dispatch_get_main_queue(), ^{
        NSString *t = nil; int k = 200;
        body = [self handle:path ctype:&t status:&k]; ct = t; code = k;
      });
      NSString *h = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
                     code, code == 200 ? @"OK" : @"Forbidden", ct, (unsigned long)body.length];
      write(c, h.UTF8String, strlen(h.UTF8String)); if (body.length) write(c, body.bytes, body.length); close(c);
    }
  });
}
@end

// ---------- icone flottante + mini-telecommande + telecommande complete ----------
@interface PCWindow : UIWindow
@end
@implementation PCWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
  UIView *v = [super hitTest:p withEvent:e];
  return (v == self || v == self.rootViewController.view) ? nil : v;   // laisse passer les touches vers l'app
}
@end

static UIColor *PCBlue(void)  { return [UIColor colorWithRed:0.16 green:0.43 blue:0.96 alpha:1]; }
static UIColor *PCGreen(void) { return [UIColor colorWithRed:0.13 green:0.68 blue:0.30 alpha:1]; }
static UIColor *PCRed(void)   { return [UIColor colorWithRed:0.86 green:0.20 blue:0.20 alpha:1]; }
static UILabel *PCLabel(NSString *t, CGFloat sz, BOOL bold) {
  UILabel *l = [UILabel new]; l.text = t; l.textColor = UIColor.whiteColor; l.numberOfLines = 0;
  l.font = bold ? [UIFont boldSystemFontOfSize:sz] : [UIFont systemFontOfSize:sz];
  return l;
}
static UIButton *PCBtnH(NSString *t, id target, SEL sel, CGFloat h, CGFloat font) {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
  [b setTitle:t forState:UIControlStateNormal]; [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:font]; b.titleLabel.adjustsFontSizeToFitWidth = YES;
  b.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1]; b.layer.cornerRadius = 8;
  [b.heightAnchor constraintEqualToConstant:h].active = YES;
  [b addTarget:target action:sel forControlEvents:UIControlEventTouchUpInside];
  return b;
}
static UIButton *PCBtn(NSString *t, id target, SEL sel) { return PCBtnH(t, target, sel, 36, 15); }
static UIStackView *PCHRow(NSArray<UIView *> *views) {
  UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:views];
  r.axis = UILayoutConstraintAxisHorizontal; r.spacing = 6; r.distribution = UIStackViewDistributionFillEqually;
  return r;
}
static UIView *PCRow(NSString *t, UISwitch *sw) {
  UIStackView *r = [UIStackView new]; r.axis = UILayoutConstraintAxisHorizontal; r.alignment = UIStackViewAlignmentCenter;
  r.spacing = 8; [r addArrangedSubview:PCLabel(t, 15, NO)]; [r addArrangedSubview:sw];
  [sw setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  return r;
}
static NSString *PCTime(double t) { int s = (int)t; return [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60]; }
static void PCHaptic(void) { [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred]; }

@interface PCUI : NSObject <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) PCWindow *win;
@property (nonatomic, strong) UIButton *bubble;    // icone flottante : tap = ON/OFF, appui long = telecommande
@property (nonatomic, strong) UILabel *badge;      // "ON" / "OFF" dans l'icone
@property (nonatomic, strong) UIView *mini;        // mini-telecommande flottante : 0 + play/pause
@property (nonatomic, strong) UIButton *miniPlay;
@property (nonatomic, strong) UIButton *dot;       // petit point quand les boutons sont caches
@property (nonatomic, strong) UIView *panel;       // telecommande complete
@property (nonatomic, strong) UIStackView *cueStack;
@property (nonatomic, strong) UIButton *vidBtn;
@property (nonatomic, strong) UIButton *playBtn;
@property (nonatomic, strong) UISwitch *onSw;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *timeLbl;
@property (nonatomic, strong) UILabel *webLbl;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UIWindow *prevKey;
@property (nonatomic) BOOL enableAfterPick;       // tap sur l'icone sans video : activer des que la video est choisie
+ (instancetype)shared;
- (void)install;
@end

@implementation PCUI
+ (instancetype)shared {
  static PCUI *u; static dispatch_once_t o;
  dispatch_once(&o, ^{ u = [PCUI new]; });
  return u;
}
- (CGPoint)clamp:(CGPoint)c size:(CGSize)sz {
  CGRect b = self.win.bounds;
  if (CGRectIsEmpty(b)) return c;
  c.x = MAX(sz.width / 2 + 4, MIN(b.size.width - sz.width / 2 - 4, c.x));
  c.y = MAX(sz.height / 2 + 20, MIN(b.size.height - sz.height / 2 - 20, c.y));
  return c;
}
- (CGPoint)savedPoint:(NSString *)k def:(CGPoint)d size:(CGSize)sz {
  NSArray *a = [PCEngine shared].prefs[k];
  if ([a isKindOfClass:NSArray.class] && a.count == 2) d = CGPointMake([a[0] doubleValue], [a[1] doubleValue]);
  return [self clamp:d size:sz];
}
- (UIButton *)miniBtn:(NSString *)t color:(UIColor *)c frame:(CGRect)f action:(SEL)sel {
  UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
  b.frame = f; b.layer.cornerRadius = f.size.height / 2; b.backgroundColor = c;
  [b setTitle:t forState:UIControlStateNormal]; [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
  [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
  return b;
}
- (void)install {
  if (self.win) return;
  UIWindowScene *sc = nil;
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
    if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) { sc = (UIWindowScene *)s; break; }
  }
  if (!sc) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self install]; });
    return;
  }
  PCEngine *E = [PCEngine shared];
  PCWindow *w = [[PCWindow alloc] initWithWindowScene:sc];
  w.windowLevel = UIWindowLevelAlert + 100; w.backgroundColor = UIColor.clearColor;
  UIViewController *vc = [UIViewController new]; vc.view.backgroundColor = UIColor.clearColor;
  w.rootViewController = vc; w.hidden = NO; self.win = w;
  UIView *host = vc.view;

  // 1) icone flottante (remplace l'activation par les boutons volume)
  UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
  b.frame = CGRectMake(0, 0, 58, 58); b.layer.cornerRadius = 29; b.layer.borderWidth = 3;
  b.layer.shadowColor = UIColor.blackColor.CGColor; b.layer.shadowOpacity = 0.4; b.layer.shadowRadius = 4; b.layer.shadowOffset = CGSizeMake(0, 2);
  UILabel *ic = PCLabel(@"🎥", 24, NO); ic.textAlignment = NSTextAlignmentCenter; ic.frame = CGRectMake(0, 5, 58, 30);
  UILabel *bd = PCLabel(@"OFF", 10, YES); bd.textAlignment = NSTextAlignmentCenter; bd.frame = CGRectMake(0, 36, 58, 13);
  [b addSubview:ic]; [b addSubview:bd]; self.badge = bd;
  [b addTarget:self action:@selector(bubbleTap) forControlEvents:UIControlEventTouchUpInside];
  UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(bubbleHold:)];
  lp.minimumPressDuration = 0.5; [b addGestureRecognizer:lp];
  [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
  b.center = [self savedPoint:@"pos_bubble" def:CGPointMake(46, 190) size:b.bounds.size];
  self.bubble = b;

  // 2) mini-telecommande : [ ⏮ 0 ] [ ⏯ ]
  UIView *m = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 136, 48)];
  m.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.85]; m.layer.cornerRadius = 24;
  UIButton *z = [self miniBtn:@"⏮ 0" color:PCBlue() frame:CGRectMake(6, 6, 74, 36) action:@selector(zeroTap)];
  [z addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(zeroHold:)]];
  self.miniPlay = [self miniBtn:@"⏯" color:[UIColor colorWithWhite:0.3 alpha:1] frame:CGRectMake(86, 6, 44, 36) action:@selector(playPause)];
  [m addSubview:z]; [m addSubview:self.miniPlay];
  [m addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
  m.center = [self savedPoint:@"pos_mini" def:CGPointMake(92, 254) size:m.bounds.size];
  m.hidden = !PCBool(E.prefs[@"mini"], YES);
  self.mini = m;

  // 3) petit point : reapparition des boutons
  UIButton *d = [UIButton buttonWithType:UIButtonTypeCustom];
  d.frame = CGRectMake(0, 0, 22, 22); d.layer.cornerRadius = 11;
  d.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3]; d.hidden = YES;
  [d addTarget:self action:@selector(showAll) forControlEvents:UIControlEventTouchUpInside];
  self.dot = d;

  [host addSubview:m]; [host addSubview:b]; [host addSubview:d];

  // derniere video utilisee : prete (en pause au debut), il suffit de toucher l'icone
  if (!E.current && [E.prefs[@"last"] isKindOfClass:NSString.class]) [E load:E.prefs[@"last"]];
  if (E.webOn) [E startServer];
  [self tick];
  self.timer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}
- (void)drag:(UIPanGestureRecognizer *)g {
  UIView *v = g.view; CGPoint t = [g translationInView:v.superview];
  v.center = [self clamp:CGPointMake(v.center.x + t.x, v.center.y + t.y) size:v.bounds.size];
  [g setTranslation:CGPointZero inView:v.superview];
  if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
    PCEngine *E = [PCEngine shared];
    E.prefs[v == self.mini ? @"pos_mini" : @"pos_bubble"] = @[@(v.center.x), @(v.center.y)];
    [E savePrefs];
  }
}
// ----- icone flottante -----
- (void)bubbleTap {
  PCEngine *E = [PCEngine shared];
  if (!E.current) { self.enableAfterPick = YES; [self chooseVideo]; return; }
  [E setOn:!E.enabled];
  PCHaptic(); [self tick];
}
- (void)bubbleHold:(UILongPressGestureRecognizer *)g {
  if (g.state != UIGestureRecognizerStateBegan) return;
  PCHaptic();
  if (self.panel) [self closePanel]; else [self buildPanel];
}
- (void)hideAll {
  [self closePanel];
  self.dot.center = self.bubble.center;
  self.bubble.hidden = YES; self.mini.hidden = YES; self.dot.hidden = NO;
}
- (void)showAll {
  self.dot.hidden = YES; self.bubble.hidden = NO;
  self.mini.hidden = !PCBool([PCEngine shared].prefs[@"mini"], YES);
}
// ----- mini-telecommande -----
- (void)zeroTap { [[PCEngine shared] restart:YES]; PCHaptic(); }
- (void)zeroHold:(UILongPressGestureRecognizer *)g {
  if (g.state != UIGestureRecognizerStateBegan) return;
  [[PCEngine shared] restart:NO]; PCHaptic();       // debut de la video, en pause (pret a lancer)
}
- (void)playPause { [[PCEngine shared] togglePlay]; [self tick]; }
- (void)tick {
  PCEngine *E = [PCEngine shared];
  BOOL on = E.enabled, playing = E.player.rate > 0;
  self.bubble.backgroundColor = on ? [PCGreen() colorWithAlphaComponent:0.95] : [UIColor colorWithWhite:0.12 alpha:0.85];
  self.bubble.layer.borderColor = (on ? UIColor.whiteColor : PCRed()).CGColor;
  self.badge.text = on ? @"ON" : @"OFF";
  [self.miniPlay setTitle:playing ? @"⏸" : @"▶︎" forState:UIControlStateNormal];
  if (!self.panel) return;
  if (self.onSw.on != on) [self.onSw setOn:on animated:YES];
  [self.playBtn setTitle:[self compact] ? (playing ? @"⏸" : @"▶︎") : (playing ? @"⏸ Pause" : @"▶︎ Lecture") forState:UIControlStateNormal];
  double dur = CMTimeGetSeconds(E.player.currentItem.duration); if (!(dur > 0) || dur > 1e9) dur = 1;
  double cur = CMTimeGetSeconds(E.player.currentTime); if (!(cur > 0)) cur = 0;
  self.slider.maximumValue = dur;
  if (!self.slider.isTracking) self.slider.value = cur;
  self.timeLbl.text = E.current ? [NSString stringWithFormat:@"%@ / %@   %@", PCTime(cur), PCTime(dur), E.current]
                                : @"Aucune vidéo : choisis-en une ci-dessous";
}
- (void)closePanel {
  [self.panel removeFromSuperview]; self.panel = nil;
  self.cueStack = nil; self.slider = nil; self.timeLbl = nil; self.vidBtn = nil;
  self.playBtn = nil; self.onSw = nil; self.webLbl = nil;
}
- (UISwitch *)sw:(BOOL)on action:(SEL)sel {
  UISwitch *s = [UISwitch new]; s.on = on;
  [s addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
  return s;
}
- (UILabel *)hint:(NSString *)t {
  UILabel *h = PCLabel(t, 11, NO); h.textColor = [UIColor colorWithWhite:0.7 alpha:1];
  return h;
}
// ----- telecommande complete (appui long sur l'icone) -----
- (void)buildPanel {
  PCEngine *E = [PCEngine shared];
  BOOL cp = [self compact];
  UIView *host = self.win.rootViewController.view;
  UIView *p = [UIView new]; p.translatesAutoresizingMaskIntoConstraints = NO;
  p.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95]; p.layer.cornerRadius = 16;
  UIScrollView *sv = [UIScrollView new]; sv.translatesAutoresizingMaskIntoConstraints = NO;
  UIStackView *st = [UIStackView new]; st.axis = UILayoutConstraintAxisVertical; st.spacing = 8;
  st.translatesAutoresizingMaskIntoConstraints = NO;
  [sv addSubview:st]; [p addSubview:sv]; [host addSubview:p];
  NSLayoutConstraint *fit = [sv.heightAnchor constraintEqualToAnchor:st.heightAnchor];
  fit.priority = UILayoutPriorityDefaultLow;    // le panneau defile si l'ecran est trop petit
  [NSLayoutConstraint activateConstraints:@[
    [sv.leadingAnchor constraintEqualToAnchor:p.leadingAnchor constant:12],
    [sv.trailingAnchor constraintEqualToAnchor:p.trailingAnchor constant:-12],
    [sv.topAnchor constraintEqualToAnchor:p.topAnchor constant:12],
    [sv.bottomAnchor constraintEqualToAnchor:p.bottomAnchor constant:-12],
    [st.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor],
    [st.bottomAnchor constraintEqualToAnchor:sv.contentLayoutGuide.bottomAnchor],
    [st.leadingAnchor constraintEqualToAnchor:sv.contentLayoutGuide.leadingAnchor],
    [st.trailingAnchor constraintEqualToAnchor:sv.contentLayoutGuide.trailingAnchor],
    [st.widthAnchor constraintEqualToAnchor:sv.frameLayoutGuide.widthAnchor], fit,
    [p.widthAnchor constraintEqualToConstant:MIN(cp ? 280 : 310, host.bounds.size.width - 20)],
    [p.centerXAnchor constraintEqualToAnchor:host.centerXAnchor]]];
  if (cp) {   // mode compact : petite telecommande collee en bas, uniquement les reperes
    [NSLayoutConstraint activateConstraints:@[
      [p.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:-16],
      [p.topAnchor constraintGreaterThanOrEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:40]]];
  } else {
    [NSLayoutConstraint activateConstraints:@[
      [p.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:40],
      [p.bottomAnchor constraintLessThanOrEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:-16]]];
  }

  if (cp) {
    // ----- mode compact : seulement les reperes (carres) + une barre d'actions -----
    UIStackView *cs = [UIStackView new]; cs.axis = UILayoutConstraintAxisVertical; cs.spacing = 8;
    [st addArrangedSubview:cs]; self.cueStack = cs;
    self.playBtn = PCBtn(@"⏯", self, @selector(playPause));
    UIButton *add = PCBtn(@"+ Temps", self, @selector(markHere)); add.backgroundColor = PCBlue();
    [st addArrangedSubview:PCHRow(@[self.playBtn, add, PCBtn(@"⚙︎", self, @selector(toggleCompact)), PCBtn(@"✕", self, @selector(closePanel))])];
    self.panel = p;
    [self reloadCues];
    [self tick];
    return;
  }
  [st addArrangedSubview:PCLabel(@"Télécommande", 18, YES)];
  [st addArrangedSubview:PCBtn(@"▾ Masquer les réglages (garder les repères)", self, @selector(toggleCompact))];
  self.timeLbl = PCLabel(@"", 12, NO); [st addArrangedSubview:self.timeLbl];
  self.onSw = [self sw:E.enabled action:@selector(swEnable:)];
  [st addArrangedSubview:PCRow(@"Caméra prank active", self.onSw)];
  // gros boutons : 0 + lecture/pause
  UIButton *zero = PCBtnH(@"⏮ 0", self, @selector(zeroTap), 54, 24); zero.backgroundColor = PCBlue();
  [zero addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(zeroHold:)]];
  self.playBtn = PCBtnH(@"⏯", self, @selector(playPause), 54, 18);
  [st addArrangedSubview:PCHRow(@[zero, self.playBtn])];
  UISlider *sl = [UISlider new]; sl.minimumValue = 0; sl.maximumValue = 1;
  [sl addTarget:self action:@selector(scrub:) forControlEvents:UIControlEventValueChanged];
  self.slider = sl; [st addArrangedSubview:sl];
  [st addArrangedSubview:PCHRow(@[PCBtn(@"-5s", self, @selector(back5)), PCBtn(@"-1s", self, @selector(back1)),
                                  PCBtn(@"+1s", self, @selector(fwd1)), PCBtn(@"+5s", self, @selector(fwd5))])];
  // video
  self.vidBtn = PCBtn(E.current ?: @"Choisir une vidéo", self, @selector(chooseVideo));
  self.vidBtn.backgroundColor = [UIColor colorWithWhite:0.32 alpha:1];
  [st addArrangedSubview:self.vidBtn];
  [st addArrangedSubview:PCHRow(@[PCBtn(@"+ Photos", self, @selector(addPhotos)), PCBtn(@"+ Fichiers", self, @selector(addFiles))])];
  UIButton *delv = PCBtn(@"🗑 Supprimer une vidéo", self, @selector(deleteVideoMenu)); delv.backgroundColor = [PCRed() colorWithAlphaComponent:0.85];
  [st addArrangedSubview:delv];
  // reperes
  [st addArrangedSubview:PCLabel(@"Repères", 15, YES)];
  [st addArrangedSubview:PCBtn(@"Ajouter ce temps (donner un nom)", self, @selector(markHere))];
  UIStackView *cs = [UIStackView new]; cs.axis = UILayoutConstraintAxisVertical; cs.spacing = 6;
  [st addArrangedSubview:cs]; self.cueStack = cs;
  // reglages
  [st addArrangedSubview:PCLabel(@"Réglages", 15, YES)];
  [st addArrangedSubview:PCLabel(@"Son", 15, YES)];
  [st addArrangedSubview:PCRow(@"Entendre la vidéo sur mon iPhone", [self sw:E.monitorOn action:@selector(swMonitor:)])];
  [st addArrangedSubview:[self sliderRow:@"Volume d'écoute" min:0 max:1 value:E.monitorVol action:@selector(slMonitor:)]];
  [st addArrangedSubview:PCRow(@"Envoyer le son de la vidéo (à la place du micro)", [self sw:E.audioOn action:@selector(swAudio:)])];
  [st addArrangedSubview:[self sliderRow:@"Volume de la vidéo envoyée" min:0 max:2 value:E.sendVol action:@selector(slSend:)]];
  [st addArrangedSubview:PCRow(@"Ajouter ma voix au son de la vidéo", [self sw:E.mixMic action:@selector(swMix:)])];
  [st addArrangedSubview:[self hint:@"Écoute : le son de la vidéo sort du haut-parleur dès qu'elle joue.\n"
                                     "Envoi coupé = c'est ton micro qui est envoyé. « Ajouter ma voix » mélange proprement ta voix et la vidéo "
                                     "(avec des écouteurs, le haut-parleur n'est pas repris par le micro)."]];
  [st addArrangedSubview:PCLabel(@"Image", 15, YES)];
  [st addArrangedSubview:[self sliderRow:@"Saturation" min:0 max:1.5 value:E.saturation action:@selector(slSat:)]];
  [st addArrangedSubview:PCBtn(@"Couleurs d'origine (100 %)", self, @selector(resetSat))];
  [st addArrangedSubview:PCLabel(@"Options avancées (désactivées par défaut)", 15, YES)];
  [st addArrangedSubview:PCRow(@"Voir aussi la vidéo sur mon écran (aperçu caméra, appel vidéo)", [self sw:PCBool(E.prefs[@"preview"], NO) action:@selector(swPreview:)])];
  [st addArrangedSubview:PCRow(@"Remplacer aussi les photos et vidéos de l'appareil photo", [self sw:PCBool(E.prefs[@"capture"], NO) action:@selector(swCapture:)])];
  [st addArrangedSubview:[self hint:@"Si un appel vidéo n'affiche plus que ta photo de profil : coupe ces deux options puis relance l'app."]];
  [st addArrangedSubview:PCLabel(@"Lecture", 15, YES)];
  [st addArrangedSubview:PCRow(@"Repartir à 0 à chaque activation", [self sw:E.zeroOnActivate action:@selector(swZero:)])];
  [st addArrangedSubview:PCRow(@"Boucle (sinon reste sur la dernière image)", [self sw:E.loop action:@selector(swLoop:)])];
  [st addArrangedSubview:PCRow(@"Mini-télécommande flottante", [self sw:PCBool(E.prefs[@"mini"], YES) action:@selector(swMini:)])];
  [st addArrangedSubview:PCRow(@"Télécommande web (même Wi-Fi)", [self sw:E.webOn action:@selector(swWeb:)])];
  self.webLbl = [self hint:@""]; [st addArrangedSubview:self.webLbl]; [self refreshWeb];
  UIButton *wb = PCBtn(@"", self, @selector(toggleWM:)); [self titleWM:wb];
  [st addArrangedSubview:wb];
  [st addArrangedSubview:PCRow(@"Qualité maximale 1080p (Snapchat / TikTok, relance l'app)", [self sw:PCBool(E.prefs[@"hq2"], NO) action:@selector(swHQ:)])];
  [st addArrangedSubview:PCBtn(@"Masquer les boutons (point discret)", self, @selector(hideAll))];
  [st addArrangedSubview:[self hint:@"Icône 🎥 : tap = ON/OFF · appui long = cette télécommande · glisser = déplacer.\n"
                                     "Bouton 0 : retour au début de la vidéo · appui long = début en pause.\n"
                                     "Le filigrane LIVE PRANK reste toujours affiché."]];
  [st addArrangedSubview:PCBtn(@"Fermer", self, @selector(closePanel))];
  self.panel = p;
  [self reloadCues];
  [self tick];
}
- (void)refreshWeb {
  PCEngine *E = [PCEngine shared];
  NSString *ip = PCLocalIP();
  self.webLbl.text = !E.webOn ? @"Télécommande web désactivée."
    : ip ? [NSString stringWithFormat:@"Ouvre http://%@:%d dans le navigateur d'un autre téléphone (même Wi-Fi).", ip, PC_PORT]
         : @"Connecte l'iPhone au Wi-Fi pour utiliser la télécommande web.";
}
- (void)scrub:(UISlider *)s {
  PCEngine *E = [PCEngine shared]; if (!E.player) return;
  [E.player pause];
  [E.player seekToTime:CMTimeMakeWithSeconds(s.value, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
  [E flush];
}
- (void)reloadCues {
  if (!self.cueStack) return;
  for (UIView *v in [self.cueStack.arrangedSubviews copy]) { [self.cueStack removeArrangedSubview:v]; [v removeFromSuperview]; }
  PCEngine *E = [PCEngine shared];
  NSDictionary *m = E.current ? E.cues[E.current] : nil;
  NSArray *names = [m.allKeys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) { return [m[a] compare:m[b]]; }];
  if ([self compact]) {                          // carres : 2 par ligne, nom en gros, temps dessous
    for (NSUInteger i = 0; i < names.count; i += 2) {
      NSMutableArray *row = [NSMutableArray new];
      for (NSUInteger j = i; j < MIN(i + 2, names.count); j++) [row addObject:[self cueButton:names[j] time:m[names[j]] tall:YES]];
      if (row.count == 1) [row addObject:[UIView new]];
      [self.cueStack addArrangedSubview:PCHRow(row)];
    }
    if (!names.count) [self.cueStack addArrangedSubview:[self hint:@"Aucun repère. Touche « + Temps » pour en ajouter. Appui long sur un repère = le supprimer."]];
    return;
  }
  for (NSString *n in names) [self.cueStack addArrangedSubview:[self cueButton:n time:m[n] tall:NO]];
  if (!names.count) [self.cueStack addArrangedSubview:[self hint:@"Aucun repère. Tap sur un repère = saut direct, appui long = supprimer."]];
}
- (UIButton *)cueButton:(NSString *)n time:(NSNumber *)t tall:(BOOL)tall {
  NSString *title = tall ? [NSString stringWithFormat:@"%@\n%@", n, PCTime(t.doubleValue)]
                         : [NSString stringWithFormat:@"%@  (%@)", n, PCTime(t.doubleValue)];
  UIButton *b = PCBtnH(title, self, @selector(cueTap:), tall ? 58 : 36, tall ? 16 : 15);
  if (tall) { b.titleLabel.numberOfLines = 2; b.titleLabel.textAlignment = NSTextAlignmentCenter; }
  b.accessibilityIdentifier = n; b.backgroundColor = PCBlue();
  [b addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(cueHold:)]];
  return b;
}
- (BOOL)compact { return PCBool([PCEngine shared].prefs[@"compact"], NO); }
- (void)toggleCompact {                          // bascule : telecommande complete <-> reperes seulement
  PCEngine *E = [PCEngine shared];
  E.prefs[@"compact"] = @(![self compact]); [E savePrefs];
  [self closePanel]; [self buildPanel];
}
- (void)deleteVideoMenu {
  NSArray *vids = PCVideos();
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Supprimer une vidéo"
    message:vids.count ? @"Choisis la vidéo à supprimer (ses repères seront supprimés aussi)." : @"Aucune vidéo à supprimer."
    preferredStyle:UIAlertControllerStyleAlert];
  for (NSString *f in vids) {
    NSString *label = [f isEqualToString:[PCEngine shared].current] ? [f stringByAppendingString:@"  (en cours)"] : f;
    [a addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [self confirmDelete:f]; }]];
  }
  [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
  [self.win.rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)confirmDelete:(NSString *)f {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Supprimer définitivement ?" message:f preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:@"Supprimer" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
    PCEngine *E = [PCEngine shared]; [E deleteVideo:f];
    [self.vidBtn setTitle:E.current ?: @"Choisir une vidéo" forState:UIControlStateNormal];
    [self reloadCues]; [self tick]; PCHaptic(); }]];
  [self.win.rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)cueTap:(UIButton *)b { [[PCEngine shared] jumpCue:b.accessibilityIdentifier]; }
- (void)cueHold:(UILongPressGestureRecognizer *)g {
  if (g.state != UIGestureRecognizerStateBegan) return;
  NSString *n = g.view.accessibilityIdentifier;
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Supprimer ce temps ?" message:n preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:@"Supprimer" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
    [[PCEngine shared] deleteCue:n]; [self reloadCues]; }]];
  [self.win.rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)swEnable:(UISwitch *)s { [[PCEngine shared] setOn:s.on]; [self tick]; }
- (void)swAudio:(UISwitch *)s { PCEngine *E = [PCEngine shared]; E.audioOn = s.on; [E savePrefs]; }
- (void)swMonitor:(UISwitch *)s {
  PCEngine *E = [PCEngine shared]; E.monitorOn = s.on; [E savePrefs];
  if (s.on && E.player.rate > 0) [E go];          // bascule sur le haut-parleur si besoin
}
- (void)swCapture:(UISwitch *)s {
  PCEngine *E = [PCEngine shared]; E.prefs[@"capture"] = @(s.on); [E savePrefs];
  if (s.on) PCCaptureHooksOn();
}
- (void)swPreview:(UISwitch *)s { PCEngine *E = [PCEngine shared]; E.prefs[@"preview"] = @(s.on); [E savePrefs]; }
- (void)swMix:(UISwitch *)s { PCEngine *E = [PCEngine shared]; E.mixMic = s.on; [E savePrefs]; }
static const void *kPCSliderLbl = &kPCSliderLbl;
static void PCSliderText(UISlider *s) {
  UILabel *l = objc_getAssociatedObject(s, kPCSliderLbl);
  l.text = [NSString stringWithFormat:@"%@ : %d %%", s.accessibilityLabel, (int)lroundf(s.value * 100)];
}
- (UIView *)sliderRow:(NSString *)t min:(float)a max:(float)b value:(float)v action:(SEL)sel {
  UIStackView *r = [UIStackView new]; r.axis = UILayoutConstraintAxisVertical; r.spacing = 2;
  UILabel *l = PCLabel(@"", 14, NO);
  UISlider *s = [UISlider new]; s.minimumValue = a; s.maximumValue = b; s.value = v; s.accessibilityLabel = t;
  objc_setAssociatedObject(s, kPCSliderLbl, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [s addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
  [r addArrangedSubview:l]; [r addArrangedSubview:s]; PCSliderText(s);
  return r;
}
- (void)slMonitor:(UISlider *)s {
  PCEngine *E = [PCEngine shared]; E.monitorVol = s.value; PCSliderText(s);
  [E savePrefs];
}
- (void)slSend:(UISlider *)s {
  if (fabsf(s.value - 1.f) < 0.04f) s.value = 1.f;     // petit cran a 100 %
  PCEngine *E = [PCEngine shared]; E.sendVol = s.value; PCSliderText(s);
  [E savePrefs];
}
- (void)slSat:(UISlider *)s {
  if (fabsf(s.value - 1.f) < 0.04f) s.value = 1.f;     // petit cran a 100 % = couleurs d'origine
  PCEngine *E = [PCEngine shared]; E.saturation = s.value; PCSliderText(s);
  [E savePrefs];
}
- (void)resetSat {
  PCEngine *E = [PCEngine shared]; E.saturation = 1.f; [E savePrefs];
  [self closePanel]; [self buildPanel];
}
- (void)swZero:(UISwitch *)s { PCEngine *E = [PCEngine shared]; E.zeroOnActivate = s.on; [E savePrefs]; }
- (void)swLoop:(UISwitch *)s { PCEngine *E = [PCEngine shared]; E.loop = s.on; [E savePrefs]; }
- (void)titleWM:(UIButton *)b {
  BOOL top = PCBool([PCEngine shared].prefs[@"wm_top"], NO);
  [b setTitle:top ? @"Filigrane LIVE PRANK : en haut (toucher = en bas)" : @"Filigrane LIVE PRANK : en bas (toucher = en haut)" forState:UIControlStateNormal];
}
- (void)toggleWM:(UIButton *)b {                 // la position change, le filigrane reste toujours visible
  PCEngine *E = [PCEngine shared];
  E.prefs[@"wm_top"] = @(!PCBool(E.prefs[@"wm_top"], NO)); [E savePrefs];
  [self titleWM:b];
}
- (void)swHQ:(UISwitch *)s { PCEngine *E = [PCEngine shared]; E.prefs[@"hq2"] = @(s.on); [E savePrefs]; }
- (void)swMini:(UISwitch *)s {
  PCEngine *E = [PCEngine shared]; E.prefs[@"mini"] = @(s.on); [E savePrefs];
  self.mini.hidden = !s.on;
}
- (void)swWeb:(UISwitch *)s {
  PCEngine *E = [PCEngine shared]; E.webOn = s.on; [E savePrefs];
  if (s.on) [E startServer];
  [self refreshWeb];
}
- (void)back5 { [[PCEngine shared] seekBy:-5]; }
- (void)back1 { [[PCEngine shared] seekBy:-1]; }
- (void)fwd1 { [[PCEngine shared] seekBy:1]; }
- (void)fwd5 { [[PCEngine shared] seekBy:5]; }
- (void)markHere {
  PCEngine *E = [PCEngine shared]; if (!E.current) return;
  NSString *def = [NSString stringWithFormat:@"Temps %lu", (unsigned long)(((NSDictionary *)E.cues[E.current]).count + 1)];
  self.prevKey = nil;
  for (UIWindow *w in self.win.windowScene.windows) if (w != self.win && w.isKeyWindow) self.prevKey = w;
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Nom de ce temps" message:nil preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = def; }];
  __weak UIAlertController *wa = a;
  [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { [self.prevKey makeKeyWindow]; }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Ajouter" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
    NSString *n = wa.textFields.firstObject.text; if (!n.length) n = def;
    [E markCue:n]; [self reloadCues]; [self.prevKey makeKeyWindow]; }]];
  [self.win makeKeyWindow];
  [self.win.rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)useVideo:(NSString *)f {                 // charge la video ; active si demande par l'icone
  PCEngine *E = [PCEngine shared];
  if (![E load:f]) { self.enableAfterPick = NO; return; }
  [self.vidBtn setTitle:E.current forState:UIControlStateNormal];
  if (self.enableAfterPick) { self.enableAfterPick = NO; [E setOn:YES]; PCHaptic(); }
  [self reloadCues]; [self tick];
}
- (void)chooseVideo {
  NSArray *vids = PCVideos();
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Vidéo"
    message:vids.count ? nil : @"Aucune vidéo pour l'instant : ajoutes-en une." preferredStyle:UIAlertControllerStyleAlert];
  for (NSString *f in vids)
    [a addAction:[UIAlertAction actionWithTitle:f style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self useVideo:f]; }]];
  [a addAction:[UIAlertAction actionWithTitle:@"+ Ajouter depuis Photos" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self addPhotos]; }]];
  [a addAction:[UIAlertAction actionWithTitle:@"+ Ajouter depuis Fichiers" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self addFiles]; }]];
  [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { self.enableAfterPick = NO; }]];
  [self.win.rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)addPhotos {
  PHPickerConfiguration *c = [[PHPickerConfiguration alloc] init];
  c.filter = [PHPickerFilter videosFilter]; c.selectionLimit = 0;
  PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:c];
  pk.delegate = self;
  [self.win.rootViewController presentViewController:pk animated:YES completion:nil];
}
- (void)addFiles {
  UIDocumentPickerViewController *d = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie] asCopy:YES];
  d.delegate = self; d.allowsMultipleSelection = YES;
  [self.win.rootViewController presentViewController:d animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (!results.count) self.enableAfterPick = NO;
  for (PHPickerResult *r in results) {
    [r.itemProvider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *err) {
      if (url) [self importURL:url];
    }];
  }
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  for (NSURL *u in urls) [self importURL:u];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c { self.enableAfterPick = NO; }
- (void)importURL:(NSURL *)url {
  NSString *name = [NSString stringWithFormat:@"%ld_%@", (long)[NSDate date].timeIntervalSince1970, url.lastPathComponent];
  NSString *dst = [PC_DIR stringByAppendingPathComponent:name];
  [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
  if ([[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:nil]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self useVideo:name]; });
  }
}
@end


// ---------- apercu a l'ecran : la video remplace aussi l'image de AVCaptureVideoPreviewLayer ----------
// (appareil photo WhatsApp, petite fenetre "moi" pendant un appel video...)
static const void *kPCOverlay = &kPCOverlay;
@interface PCPreview : NSObject
@property (nonatomic, strong) NSHashTable *layers;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) NSUInteger lastGen;
@property (nonatomic) BOOL shown;
@property (nonatomic) NSUInteger scan;
+ (instancetype)shared;
- (void)add:(CALayer *)l;
- (void)start;
@end
@implementation PCPreview
+ (instancetype)shared {
  static PCPreview *p; static dispatch_once_t o;
  dispatch_once(&o, ^{ p = [PCPreview new]; p.layers = [NSHashTable weakObjectsHashTable]; });
  return p;
}
- (void)add:(CALayer *)l { if (l) [self.layers addObject:l]; }
- (void)start {                                   // appele quand la camera prank passe ON
  if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self start]; }); return; }
  if (self.link) return;
  self.scan = 0;
  self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
  self.link.preferredFramesPerSecond = 30;
  [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
static void PCFindPreviews(CALayer *l, int depth, PCPreview *p) {   // lecture seule de l'arbre des calques
  if (!l || depth > 40) return;
  if ([l isKindOfClass:AVCaptureVideoPreviewLayer.class]) { [p add:l]; return; }
  for (CALayer *c in [l.sublayers copy]) PCFindPreviews(c, depth + 1, p);
}
- (void)rescan {
  for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
    if (![sc isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *w in ((UIWindowScene *)sc).windows) if (![w isKindOfClass:PCWindow.class]) PCFindPreviews(w.layer, 0, self);
  }
}
static BOOL PCMirrored(CALayer *l) {          // l'app retourne-t-elle l'apercu (effet miroir) ?
  CGFloat det = 1;
  for (CALayer *x = l; x; x = x.superlayer) {
    CGAffineTransform t = CATransform3DGetAffineTransform(x.transform);
    det *= (t.a * t.d - t.b * t.c);
  }
  return det < 0;
}
- (void)tick {
  PCEngine *E = [PCEngine shared];
  BOOL want = E.enabled && E.out && PCBool(E.prefs[@"preview"], NO);
  NSArray *ls = self.layers.allObjects;
  if (!want) {                                     // OFF : on retire tout et on s'arrete (aucun effet sur l'app)
    for (CALayer *l in ls) {
      CALayer *ov = objc_getAssociatedObject(l, kPCOverlay);
      if (ov) { [ov removeFromSuperlayer]; objc_setAssociatedObject(l, kPCOverlay, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }
    self.shown = NO;
    if (!E.enabled) { [self.link invalidate]; self.link = nil; }
    return;
  }
  if ((self.scan++ % 15) == 0) { [self rescan]; ls = self.layers.allObjects; }   // ~2 fois par seconde
  BOOL any = NO;
  for (CALayer *l in ls) if (l.superlayer && !l.hidden) { any = YES; break; }
  if (!any) return;
  CIImage *raw = [E grabFrame];
  if (!raw || (self.shown && E.frameGen == self.lastGen)) return;   // rien de nouveau
  CIImage *img = [E styled:raw upright:YES];
  CGFloat m = MAX(img.extent.size.width, img.extent.size.height);
  if (m > 960) img = [img imageByApplyingTransform:CGAffineTransformMakeScale(960 / m, 960 / m)];
  CGImageRef cg = [E.ci createCGImage:img fromRect:img.extent format:kCIFormatBGRA8 colorSpace:PCSRGB()];
  if (!cg) return;                                                   // pas d'image : on ne cache rien
  self.lastGen = E.frameGen;
  [CATransaction begin]; [CATransaction setDisableActions:YES];
  for (AVCaptureVideoPreviewLayer *l in ls) {
    if (!l.superlayer) continue;
    CALayer *ov = objc_getAssociatedObject(l, kPCOverlay);
    if (!ov) {
      ov = [CALayer new]; ov.masksToBounds = YES;
      objc_setAssociatedObject(l, kPCOverlay, ov, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (ov.superlayer != l) [l addSublayer:ov];
    NSString *g = [l respondsToSelector:@selector(videoGravity)] ? l.videoGravity : AVLayerVideoGravityResizeAspectFill;
    ov.contentsGravity = [g isEqualToString:AVLayerVideoGravityResizeAspect] ? kCAGravityResizeAspect
                       : [g isEqualToString:AVLayerVideoGravityResize] ? kCAGravityResize : kCAGravityResizeAspectFill;
    ov.zPosition = 10000; ov.frame = l.bounds;
    ov.affineTransform = PCMirrored(l) ? CGAffineTransformMakeScale(-1, 1) : CGAffineTransformIdentity;   // texte lisible
    ov.contents = (__bridge id)cg; ov.hidden = NO;
  }
  [CATransaction commit];
  CGImageRelease(cg);
  self.shown = YES;
}
@end

static void PCPreviewStart(void) { [[PCPreview shared] start]; }

// ---------- photos : AVCapturePhotoOutput / AVCaptureStillImageOutput ----------
@interface PCShot : NSObject {
  CVPixelBufferRef _pb; CGImageRef _cg;
}
@property (nonatomic, strong) CIImage *img;
@property (nonatomic, strong) NSData *jpegData;
- (NSData *)jpeg;
- (CVPixelBufferRef)pixelBuffer;
- (CGImageRef)cgImage;
@end
@implementation PCShot
- (NSData *)jpeg {
  @synchronized (self) {
    if (!_jpegData) _jpegData = [[PCEngine shared].ci JPEGRepresentationOfImage:self.img colorSpace:PCSRGB()
                                   options:@{(id)kCGImageDestinationLossyCompressionQuality: @0.92}];
    return _jpegData;
  }
}
- (CVPixelBufferRef)pixelBuffer {
  @synchronized (self) { if (!_pb) _pb = [[PCEngine shared] renderImage:self.img maxSide:0]; return _pb; }
}
- (CGImageRef)cgImage {
  @synchronized (self) {
    if (!_cg) _cg = [[PCEngine shared].ci createCGImage:self.img fromRect:self.img.extent format:kCIFormatRGBA8 colorSpace:PCSRGB()];
    return _cg;
  }
}
- (void)dealloc { if (_pb) CVPixelBufferRelease(_pb); if (_cg) CGImageRelease(_cg); }
@end

static NSMutableDictionary *gShots;   // uniqueID des reglages photo -> image prank
static PCShot *gLastShot;
static PCShot *PCTakeShot(void) {
  PCEngine *E = [PCEngine shared];
  if (!E.enabled) return nil;
  CIImage *img = [E styled:[E grabFrame] upright:YES];
  if (!img) return nil;
  PCShot *s = [PCShot new]; s.img = img;
  return s;
}
static PCShot *PCShotFor(AVCapturePhoto *p) {
  @synchronized (gShots) { return gShots[@(p.resolvedSettings.uniqueID)]; }
}

// ---------- videos : AVCaptureMovieFileOutput -> le fichier est refait avec la video prank ----------
static void PCRenderMovie(NSURL *rec, NSDictionary *cfg, void (^done)(void)) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
    BOOL ok = NO;
    NSString *ext = rec.pathExtension.length ? rec.pathExtension : @"mov";
    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"pc_%@.%@", [NSUUID UUID].UUIDString, ext]]];
    do {
      AVURLAsset *ra = [AVURLAsset URLAssetWithURL:rec options:nil];
      AVURLAsset *sa = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:cfg[@"path"]] options:nil];
      AVAssetTrack *sv = [sa tracksWithMediaType:AVMediaTypeVideo].firstObject;
      if (!sv) break;
      double rdur = CMTimeGetSeconds(ra.duration), sdur = CMTimeGetSeconds(sa.duration);
      if (!(rdur > 0) || !(sdur > 0)) break;
      double len = MIN(rdur, sdur);
      double st = MAX(0, MIN([cfg[@"start"] doubleValue], sdur - len));
      CMTime clen = CMTimeMakeWithSeconds(len, 600);
      AVMutableComposition *c = [AVMutableComposition composition];
      AVMutableCompositionTrack *cv = [c addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
      if (![cv insertTimeRange:CMTimeRangeMake(CMTimeMakeWithSeconds(st, 600), clen) ofTrack:sv atTime:kCMTimeZero error:nil]) break;
      NSMutableArray *params = [NSMutableArray new];
      BOOL audioOn = [cfg[@"audio"] boolValue], mix = [cfg[@"mix"] boolValue];
      float send = [cfg[@"send"] floatValue];
      AVAssetTrack *sat = [sa tracksWithMediaType:AVMediaTypeAudio].firstObject, *rat = [ra tracksWithMediaType:AVMediaTypeAudio].firstObject;
      if (audioOn && sat && send > 0.001f) {          // son de la video
        AVMutableCompositionTrack *ca = [c addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        if ([ca insertTimeRange:CMTimeRangeMake(CMTimeMakeWithSeconds(st, 600), clen) ofTrack:sat atTime:kCMTimeZero error:nil]) {
          AVMutableAudioMixInputParameters *p = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:ca];
          [p setVolume:MIN(send, 1.f) atTime:kCMTimeZero]; [params addObject:p];
        }
      }
      if ((!audioOn || mix) && rat) {                 // mon micro (seul, ou melange a la video)
        AVMutableCompositionTrack *cm = [c addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        if ([cm insertTimeRange:CMTimeRangeMake(kCMTimeZero, clen) ofTrack:rat atTime:kCMTimeZero error:nil]) {
          AVMutableAudioMixInputParameters *p = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:cm];
          [p setVolume:1 atTime:kCMTimeZero]; [params addObject:p];
        }
      }
      NSError *err = nil;
      AVAssetReader *rd = [AVAssetReader assetReaderWithAsset:c error:&err];
      if (!rd) break;
      rd.timeRange = CMTimeRangeMake(kCMTimeZero, clen);
      AVAssetReaderTrackOutput *vo = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:cv outputSettings:
        @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferIOSurfacePropertiesKey: @{}}];
      vo.alwaysCopiesSampleData = NO;
      if (![rd canAddOutput:vo]) break;
      [rd addOutput:vo];
      AVAssetReaderAudioMixOutput *ao = nil;
      NSArray *atr = [c tracksWithMediaType:AVMediaTypeAudio];
      NSDictionary *pcm = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @44100, AVNumberOfChannelsKey: @2,
                            AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO,
                            AVLinearPCMIsNonInterleaved: @NO};
      if (atr.count) {
        ao = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:atr audioSettings:pcm];
        AVMutableAudioMix *am = [AVMutableAudioMix audioMix]; am.inputParameters = params; ao.audioMix = am;
        if ([rd canAddOutput:ao]) [rd addOutput:ao]; else ao = nil;
      }
      CGImagePropertyOrientation o = PCOrient(sv.preferredTransform);
      CGSize ns = sv.naturalSize;
      BOOL swap = o == kCGImagePropertyOrientationLeft || o == kCGImagePropertyOrientationRight;
      size_t W = ((size_t)lround(swap ? ns.height : ns.width)) & ~(size_t)1, H = ((size_t)lround(swap ? ns.width : ns.height)) & ~(size_t)1;
      if (W < 16 || H < 16) break;
      AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:tmp fileType:[ext.lowercaseString isEqualToString:@"mp4"] ? AVFileTypeMPEG4 : AVFileTypeQuickTimeMovie error:&err];
      if (!w) break;
      AVAssetWriterInput *wv = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:
        @{AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(W), AVVideoHeightKey: @(H),
          AVVideoColorPropertiesKey: @{AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2}}];
      wv.expectsMediaDataInRealTime = NO;
      AVAssetWriterInputPixelBufferAdaptor *ad = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:wv
        sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferWidthKey: @(W),
                                      (id)kCVPixelBufferHeightKey: @(H), (id)kCVPixelBufferIOSurfacePropertiesKey: @{}}];
      if (![w canAddInput:wv]) break;
      [w addInput:wv];
      AVAssetWriterInput *wa = nil;
      if (ao) {
        wa = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:
          @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @44100, AVNumberOfChannelsKey: @2, AVEncoderBitRateKey: @128000}];
        wa.expectsMediaDataInRealTime = NO;
        if ([w canAddInput:wa]) [w addInput:wa]; else wa = nil;
      }
      if (![rd startReading] || ![w startWriting]) { [rd cancelReading]; [w cancelWriting]; break; }
      [w startSessionAtSourceTime:kCMTimeZero];
      CIContext *ctx = [CIContext contextWithOptions:nil];
      CIImage *wm = PCMakeWM(CGSizeMake(W, H), [cfg[@"top"] boolValue]);
      float sat2 = [cfg[@"sat"] floatValue];
      dispatch_group_t g = dispatch_group_create();
      dispatch_queue_t qv = dispatch_queue_create("pc.export.v", DISPATCH_QUEUE_SERIAL);
      dispatch_queue_t qa = dispatch_queue_create("pc.export.a", DISPATCH_QUEUE_SERIAL);
      __block BOOL vDone = NO, aDone = NO;
      dispatch_group_enter(g);
      [wv requestMediaDataWhenReadyOnQueue:qv usingBlock:^{
        while (!vDone && wv.isReadyForMoreMediaData) { @autoreleasepool {
          CMSampleBufferRef sb = [vo copyNextSampleBuffer];
          if (!sb) { vDone = YES; [wv markAsFinished]; dispatch_group_leave(g); continue; }
          CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
          CVPixelBufferRef out = NULL;
          if (ib && ad.pixelBufferPool) CVPixelBufferPoolCreatePixelBuffer(NULL, ad.pixelBufferPool, &out);
          if (out) {
            CIImage *img = [CIImage imageWithCVPixelBuffer:ib];
            if (o != kCGImagePropertyOrientationUp) img = [img imageByApplyingCGOrientation:o];
            img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-img.extent.origin.x, -img.extent.origin.y)];
            if (img.extent.size.width != W || img.extent.size.height != H)
              img = [img imageByApplyingTransform:CGAffineTransformMakeScale(W / img.extent.size.width, H / img.extent.size.height)];
            img = [wm imageByCompositingOverImage:PCSaturate(img, sat2)];
            PCTag709(out);
            [ctx render:img toCVPixelBuffer:out bounds:CGRectMake(0, 0, W, H) colorSpace:PCSRGB()];
            [ad appendPixelBuffer:out withPresentationTime:CMSampleBufferGetPresentationTimeStamp(sb)];
            CVPixelBufferRelease(out);
          }
          CFRelease(sb);
        } }
      }];
      if (wa) {
        dispatch_group_enter(g);
        [wa requestMediaDataWhenReadyOnQueue:qa usingBlock:^{
          while (!aDone && wa.isReadyForMoreMediaData) {
            CMSampleBufferRef sb = [ao copyNextSampleBuffer];
            if (!sb) { aDone = YES; [wa markAsFinished]; dispatch_group_leave(g); break; }
            [wa appendSampleBuffer:sb]; CFRelease(sb);
          }
        }];
      }
      if (dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC))) != 0 || rd.status == AVAssetReaderStatusFailed) {
        [rd cancelReading]; [w cancelWriting]; break;
      }
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      [w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
      dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
      ok = w.status == AVAssetWriterStatusCompleted;
    } while (0);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (ok) {
      NSURL *bak = [rec URLByAppendingPathExtension:@"pcbak"];
      [fm removeItemAtURL:bak error:nil];
      if ([fm moveItemAtURL:rec toURL:bak error:nil]) {
        if ([fm moveItemAtURL:tmp toURL:rec error:nil]) [fm removeItemAtURL:bak error:nil];
        else [fm moveItemAtURL:bak toURL:rec error:nil];        // en cas d'echec : on garde l'enregistrement d'origine
      }
    }
    [fm removeItemAtURL:tmp error:nil];
    dispatch_async(dispatch_get_main_queue(), done);
  } });
}

@interface PCRecProxy : NSObject <AVCaptureFileOutputRecordingDelegate>
@property (nonatomic, strong) id real;
@property (nonatomic, strong) NSDictionary *cfg;
@end
static NSMutableSet *gRecProxies;
@implementation PCRecProxy
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [self.real respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.real; }
- (void)captureOutput:(AVCaptureFileOutput *)o didFinishRecordingToOutputFileAtURL:(NSURL *)u fromConnections:(NSArray *)cs error:(NSError *)e {
  id real = self.real;
  BOOL fine = u.path && [[NSFileManager defaultManager] fileExistsAtPath:u.path] &&
              (!e || [e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] boolValue]);
  void (^finish)(void) = ^{
    [real captureOutput:o didFinishRecordingToOutputFileAtURL:u fromConnections:cs error:e];
    @synchronized (gRecProxies) { [gRecProxies removeObject:self]; }
  };
  if (fine && self.cfg) PCRenderMovie(u, self.cfg, finish); else finish();
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
  if (d) { PCPatch([d class]); dispatch_async(dispatch_get_main_queue(), ^{ [[PCUI shared] install]; }); }
  %orig;
}
%end

%hook AVCaptureAudioDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(dispatch_queue_t)q {
  if (d) { PCPatch([d class]); }
  %orig;
}
%end

static BOOL PCTargetApp(void) {
  static BOOL r; static dispatch_once_t o;
  dispatch_once(&o, ^{
    NSString *b = NSBundle.mainBundle.bundleIdentifier ?: @"";
    r = [@[@"com.toyopagroup.picaboo", @"com.zhiliaoapp.musically", @"net.whatsapp.WhatsApp", @"net.whatsapp.WhatsAppSMB", @"com.facebook.Messenger"] containsObject:b];
  });
  return r;
}
// Qualite maximale (option, OFF par defaut) : forcait le 1080p, y compris dans WhatsApp, ce qui coupait l'image
// des appels video meme camera prank desactivee (les appels demandent une petite resolution).
// Desormais : installe seulement si l'option est activee, et jamais dans WhatsApp / Messenger.
static BOOL PCHQApp(void) {
  NSString *b = NSBundle.mainBundle.bundleIdentifier ?: @"";
  return [@[@"com.toyopagroup.picaboo", @"com.zhiliaoapp.musically"] containsObject:b];
}
%group PCHQ
%hook AVCaptureSession
- (void)setSessionPreset:(AVCaptureSessionPreset)preset {
  if (PCBool([PCEngine shared].prefs[@"hq2"], NO) &&
      ([preset isEqualToString:AVCaptureSessionPresetMedium] || [preset isEqualToString:AVCaptureSessionPresetLow] ||
       [preset isEqualToString:AVCaptureSessionPreset640x480] || [preset isEqualToString:AVCaptureSessionPreset1280x720] ||
       [preset isEqualToString:@"AVCaptureSessionPreset960x540"]) &&
      [self canSetSessionPreset:AVCaptureSessionPreset1920x1080]) { %orig(AVCaptureSessionPreset1920x1080); return; }
  %orig;
}
%end
%end



// ---------- photos / videos de l'appareil photo : installes seulement si l'option est activee ----------
%group PCCapture
%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)st delegate:(id)d {
  PCShot *sh = PCCaptureOn() ? PCTakeShot() : nil;
  @synchronized (gShots) {
    if (gShots.count > 16) [gShots removeAllObjects];
    if (sh) gShots[@(st.uniqueID)] = sh; else [gShots removeObjectForKey:@(st.uniqueID)];
  }
  gLastShot = sh;
  %orig;
}
+ (NSData *)JPEGPhotoDataRepresentationForJPEGSampleBuffer:(CMSampleBufferRef)a previewPhotoSampleBuffer:(CMSampleBufferRef)b {
  PCShot *sh = gLastShot; NSData *j = sh ? [sh jpeg] : nil;
  return j ?: %orig;
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation { PCShot *sh = PCShotFor(self); NSData *j = sh ? [sh jpeg] : nil; return j ?: %orig; }
- (NSData *)fileDataRepresentationWithCustomizer:(id)c { PCShot *sh = PCShotFor(self); NSData *j = sh ? [sh jpeg] : nil; return j ?: %orig; }
- (NSData *)fileDataRepresentationWithReplacementMetadata:(NSDictionary *)m replacementEmbeddedThumbnailPhotoFormat:(NSDictionary *)f replacementEmbeddedThumbnailPixelBuffer:(CVPixelBufferRef)pb replacementDepthData:(AVDepthData *)dd {
  PCShot *sh = PCShotFor(self); NSData *j = sh ? [sh jpeg] : nil; return j ?: %orig;
}
- (CVPixelBufferRef)pixelBuffer { PCShot *sh = PCShotFor(self); CVPixelBufferRef p = sh ? [sh pixelBuffer] : NULL; return p ?: %orig; }
- (CVPixelBufferRef)previewPixelBuffer { PCShot *sh = PCShotFor(self); CVPixelBufferRef p = sh ? [sh pixelBuffer] : NULL; return p ?: %orig; }
- (CGImageRef)CGImageRepresentation { PCShot *sh = PCShotFor(self); CGImageRef c = sh ? [sh cgImage] : NULL; return c ?: %orig; }
- (CGImageRef)previewCGImageRepresentation { PCShot *sh = PCShotFor(self); CGImageRef c = sh ? [sh cgImage] : NULL; return c ?: %orig; }
- (NSDictionary *)metadata {                  // l'image prank est deja a l'endroit : pas de rotation supplementaire
  NSDictionary *m = %orig;
  if (!PCShotFor(self)) return m;
  NSMutableDictionary *mm = [m mutableCopy] ?: [NSMutableDictionary new];
  mm[(id)kCGImagePropertyOrientation] = @1;
  NSMutableDictionary *tiff = [mm[(id)kCGImagePropertyTIFFDictionary] mutableCopy];
  if (tiff) { tiff[(id)kCGImagePropertyTIFFOrientation] = @1; mm[(id)kCGImagePropertyTIFFDictionary] = tiff; }
  return mm;
}
%end

%hook AVCaptureStillImageOutput
- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)c completionHandler:(id)h {
  gLastShot = PCCaptureOn() ? PCTakeShot() : nil;
  %orig;
}
+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)sb {
  PCShot *sh = gLastShot; NSData *j = sh ? [sh jpeg] : nil;
  return j ?: %orig;
}
%end

// ---------- videos enregistrees ----------
%hook AVCaptureMovieFileOutput
- (void)startRecordingToOutputFileURL:(NSURL *)url recordingDelegate:(id)d {
  NSDictionary *cfg = (d && PCCaptureOn()) ? [[PCEngine shared] recordConfig] : nil;
  if (!cfg) { %orig; return; }
  PCRecProxy *p = [PCRecProxy new]; p.real = d; p.cfg = cfg;
  @synchronized (gRecProxies) { [gRecProxies addObject:p]; }
  %orig(url, p);
}
%end

%end

static BOOL PCCaptureOn(void) { return PCBool([PCEngine shared].prefs[@"capture"], NO); }
static void PCCaptureHooksOn(void) {
  static BOOL done = NO;
  if (done) return;
  done = YES;
  %init(PCCapture);
}

// Apps qui lisent le micro via une AudioUnit (appels WhatsApp / Messenger, WebRTC...) : on remplace les echantillons du micro
%hookf(OSStatus, AudioUnitRender, AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *io) {
  OSStatus r = %orig;
  if (r == noErr && bus == 1) [[PCEngine shared] replaceAudioUnit:unit abl:io frames:frames];
  return r;
}

%ctor {
  %init;                                          // hooks de base (camera des appels / notes video, micro)
  if (PCHQApp() && PCBool([PCEngine shared].prefs[@"hq2"], NO)) %init(PCHQ);
  patched = [NSMutableSet new]; gShots = [NSMutableDictionary new]; gRecProxies = [NSMutableSet new];
  if (PCTargetApp() && PCCaptureOn()) {           // option photos/videos : hooks + icone dans l'appareil photo
    PCCaptureHooksOn();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
      queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { [[PCUI shared] install]; }];
  }
}
