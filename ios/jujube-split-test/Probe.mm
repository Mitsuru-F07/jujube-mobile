#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "IPhoneTlsBridge.h"
#include "llama.h"
#include "ggml-rpc.h"
#include <chrono>
#include <string>
#include <vector>
#include <algorithm>
#include <CommonCrypto/CommonDigest.h>
static_assert(RPC_PROTO_MAJOR_VERSION == 10, "The bridge smoke uses RPCv10");
static void splitModelLog(ggml_log_level level, const char *text, void *) {
 @autoreleasepool {
  NSString *line=text?[NSString stringWithUTF8String:text]:nil;
  if (!line) return;
  NSString *lower=line.lowercaseString;
  if (level>=GGML_LOG_LEVEL_WARN ||
      [line containsString:@"assigned to device"] ||
      [line containsString:@"offloaded"] ||
      [line containsString:@"RPC"] ||
      [lower containsString:@"failed"] ||
      [lower containsString:@"error"] ||
      [lower containsString:@"not enough"] ||
      [lower containsString:@"cannot allocate"] ||
      [lower containsString:@"buffer size"] ||
      [lower containsString:@"memory required"]) {
   BridgeAudit([line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
  }
 }
}

// Only trusted, already-downloaded GGUF weights can enter the secure relay.
static NSString *verifiedInklingGGUF(void) {
 @autoreleasepool {
  NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Inkling-2-Mini-AD-IQ1_S.gguf"];
  NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
  if([attrs[NSFileSize] unsignedLongLongValue]!=6881463904ULL) {
    BridgeAudit(@"FAIL Inkling model missing or wrong file length; no network");
    return nil;
  }
  NSInputStream *stream=[NSInputStream inputStreamWithFileAtPath:path];
  [stream open];
  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);
  std::vector<uint8_t> buf(65536);
  uint64_t received=0;
  BOOL valid=YES;
  NSInteger n;
  while((n=[stream read:buf.data() maxLength:buf.size()])!=0){
    if(n<0 || received+(uint64_t)n>6881463904ULL) {valid=NO;break;}
    CC_SHA256_Update(&ctx,buf.data(),(CC_LONG)n);
    received+=(uint64_t)n;
  }
  [stream close];
  if(!valid || received!=6881463904ULL){BridgeAudit(@"FAIL Inkling model read/integrity");return nil;}
  unsigned char hash[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(hash,&ctx);
  NSMutableString *hex=[NSMutableString new];
  for(unsigned char c:hash)[hex appendFormat:@"%02x",c];
  if(![hex isEqualToString:@"4d3cab7e88016548136e13f7ec465db7fc49ab8cf9559a60f3daad1f3f15c9d5"]){
    BridgeAudit(@"FAIL Inkling model hash mismatch; no network");
    return nil;
  }
  BridgeAudit(@"Verified Inkling GGUF length and SHA256");
  return path;
 }
}

static NSString *runModel(bool rpc,bool inkling=false, NSArray<NSDictionary<NSString *, NSString *> *> *chatMessages=nil) {
 @autoreleasepool {
  NSString *path=inkling?verifiedInklingGGUF():
     [[NSBundle mainBundle] pathForResource:@"Qwen3.5-0.8B-Q4_K_M" ofType:@"gguf"];
  if(!path)return @"FAIL: missing or unverified model";
  IPhoneTlsBridge bridge;
  if (rpc && !bridge.start()) return @"FAIL: encrypted bridge startup";
  if (rpc) llama_log_set(splitModelLog, nullptr);
  llama_backend_init();
  std::vector<ggml_backend_dev_t> rpcDevices;
  if (rpc) {
   auto server=ggml_backend_rpc_add_server("127.0.0.1:55155");
   if (!server || !ggml_backend_reg_dev_count(server)) {
    BridgeAudit(@"FAIL GGML RPC device discovery through authenticated bridge");
    return @"FAIL: GGML RPC device discovery";
   }
   for (size_t i=0; i<ggml_backend_reg_dev_count(server); ++i) {
    auto device=ggml_backend_reg_dev_get(server,i);
    rpcDevices.push_back(device);
    BridgeAudit([NSString stringWithFormat:@"GGML RPC device %s via 127.0.0.1:55155 to 192.0.2.1:55443",
                 ggml_backend_dev_name(device)]);
   }
   rpcDevices.push_back(nullptr);
  }
  // The Inkling 24 physical layers expand to 48 virtual cache slots.
  // 49 - 43 = 6: keep layers 0..5 on iPhone, offload physical layers 6..23
  // and all repeated middle passes to Pixel using the same remote weights.
  llama_model_params mp=llama_model_default_params();
  // iPhone 15 has 5.96 GiB RAM and cannot mmap a 6.88GB GGUF as one
  // address-space-backed file. Stream direct into CPU/RPC backend buffers
  // instead of mapping the complete on-disk artifact into virtual memory.
  if (inkling) mp.load_mode=LLAMA_LOAD_MODE_NONE;
  mp.n_gpu_layers=rpc?(inkling?43:12):0;
  if (rpc) {
   mp.devices=rpcDevices.data();
   BridgeAudit(inkling?@"Inkling 43/49 virtual slots on Pixel, physical 6..23 across 3 passes":
                        @"Requested 12 Qwen model layers on the discovered Pixel RPC devices");
  }
  auto start=std::chrono::steady_clock::now();
  llama_model *m=llama_model_load_from_file(path.UTF8String,mp);
  if(!m)return @"FAIL: load";
  llama_context_params cp=llama_context_default_params();
  cp.n_ctx=(inkling && chatMessages.count)?1024:(inkling?512:1024);cp.n_batch=inkling?64:128;
  cp.n_ubatch=inkling?64:128;cp.n_threads=4;cp.n_threads_batch=4;
  llama_context *ctx=llama_init_from_model(m,cp);
  if(!ctx){llama_model_free(m);return @"FAIL: context";}
  const llama_vocab *v=llama_model_get_vocab(m);
  const bool interactive=chatMessages.count>0;
  std::string prompt="The capital of France is";
  if (interactive) {
    // Format Jujube chat with the model's own GGUF chat template if supported.
    // Keep all user data local to the phone and authenticated Pixel node.
    std::vector<std::string> roles, contents;
    roles.reserve(chatMessages.count+1);
    contents.reserve(chatMessages.count+1);
    roles.emplace_back("system");
    contents.emplace_back("You are Jujube, a helpful on-device AI. Respond naturally and concisely in Japanese.");
    for (NSDictionary<NSString *, NSString *> *entry in chatMessages) {
      NSString *role=entry[@"role"];
      NSString *content=entry[@"content"];
      if (![role isEqualToString:@"user"] && ![role isEqualToString:@"assistant"]) continue;
      if (content.length>800) content=[content substringToIndex:800];
      roles.emplace_back(role.UTF8String);
      contents.emplace_back(content.UTF8String ?: "");
    }
    std::vector<llama_chat_message> messages;
    for (size_t i=0; i<roles.size(); i++) {
      messages.push_back({roles[i].c_str(),contents[i].c_str()});
    }
    // Inkling 2 Mini has its own Jinja GGUF chat template. The minimal
    // llama_chat_apply_template() API does not support it (returns -1).
    // Reconstruct its no-tools, text-only conversation message framing
    // exactly: message_system/user/model + content_text + end_message.
    // "Thinking effort level: 0" intentionally requests a direct answer.
    const char *tmpl=llama_model_chat_template(m,nullptr);
    if (!tmpl || !strstr(tmpl,"<|message_user|>") ||
        !strstr(tmpl,"<|content_text|>") ||
        !strstr(tmpl,"<|end_message|>")) {
      llama_free(ctx);llama_model_free(m);
      return @"FAIL: unsupported Inkling chat template; no plain-text fallback";
    }
    prompt="<|message_system|><|content_text|>"+contents.front()+"<|end_message|>";
    prompt+="<|message_system|><|content_text|>Thinking effort level: 0<|end_message|>";
    for (size_t i=1; i<roles.size(); i++) {
      const char *header=roles[i]=="user"?"<|message_user|>":"<|message_model|>";
      prompt+=header;
      prompt+="<|content_text|>";
      prompt+=contents[i];
      prompt+="<|end_message|>";
      if (roles[i]=="assistant") prompt+="<|content_model_end_sampling|>";
    }
    prompt+="<|message_model|><|content_text|>";
    BridgeAudit([NSString stringWithFormat:@"Jujube chat native Inkling GGUF template framing, messages=%lu, bytes=%lu",
      (unsigned long)roles.size(),(unsigned long)prompt.size()]);
  }
  std::vector<llama_token> input(interactive?1024:256);
  int n=llama_tokenize(v,prompt.data(),(int)prompt.size(),input.data(),(int)input.size(),true,true);
  if(n<1 || n>(int)input.size() || (interactive && n>800)) {
   llama_free(ctx);llama_model_free(m);return @"FAIL: prompt tokenization / chat context limit";
  }
  // llama_context::decode has a hard assertion n_tokens_all <= n_batch.
  // Inkling has n_batch=64. User text and prior turns can exceed this and
  // SIGABRT before returning an error. Prefill in bounded groups of tokens.
  const int batchLimit=inkling?64:128;
  BridgeAudit([NSString stringWithFormat:@"Jujube prompt tokens=%d n_batch=%d chunks=%d",
       n,batchLimit,(n+batchLimit-1)/batchLimit]);
  bool failedPrefill=false;
  for(int pos=0;pos<n;pos+=batchLimit) {
   const int count=std::min(batchLimit,n-pos);
   if(llama_decode(ctx,llama_batch_get_one(input.data()+pos,count))) {
    failedPrefill=true;
    BridgeAudit([NSString stringWithFormat:@"FAIL prompt decode chunk pos=%d count=%d",pos,count]);
    break;
   }
  }
  if(failedPrefill) {
   llama_free(ctx);llama_model_free(m);return @"FAIL: prompt prefill (bounded batch)";
  }
  llama_sampler *sampler=llama_sampler_init_greedy();std::string text,ids;
  bool decodeFailed=false;
  const int maxTokens=interactive?128:(inkling?8:20);
  for(int i=0;i<maxTokens;i++){
   llama_token t=llama_sampler_sample(sampler,ctx,-1);
   if(t<0 || llama_vocab_is_eog(v,t))break;
   char b[8192]={};int size=llama_token_to_piece(v,t,b,sizeof(b),0,true);
   if(size<0 || static_cast<size_t>(size)>=sizeof(b))break;
   // Inkling end_message is a structural delimiter, not user-facing text.
   const std::string piece(b,(size_t)size);
   if (interactive &&
       (piece=="<|end_message|>" || piece=="<|content_model_end_sampling|>")) break;
   text.append(b,size);ids+=std::to_string(t)+",";
   llama_sampler_accept(sampler,t);
   if(i<maxTokens-1 && llama_decode(ctx,llama_batch_get_one(&t,1))) {
    decodeFailed=true;
    break;
   }
  }
  llama_sampler_free(sampler);llama_synchronize(ctx);
  auto seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
  NSString *result=[NSString stringWithFormat:@"MODE=%@\nOUTPUT=%@\nIDS=%s\nTIME=%.3f s",interactive?@"INKLING_CHAT":(inkling?@"INKLING_RPC":(rpc?@"RPC":@"LOCAL")),[NSString stringWithUTF8String:text.c_str()]?:@"(bad utf8)",ids.c_str(),seconds];
  llama_free(ctx);llama_model_free(m);llama_backend_free();
  if (rpc && (decodeFailed || ids.empty())) return @"FAIL: split token generation";
  return result;
 }
}

@interface ProbeSceneDelegate:UIResponder<UIWindowSceneDelegate>
@property(strong,nonatomic)UIWindow *window;
@property(strong,nonatomic)UITextView *label;
@property(strong,nonatomic)UITextView *promptBox;
@property(strong,nonatomic)UIButton *chatButton;
@property(strong,nonatomic)NSMutableArray<NSDictionary<NSString *, NSString *> *> *chatHistory;
@property(nonatomic)BOOL chatBusy;
@end
@implementation ProbeSceneDelegate

// Interactive conversation is explicitly user-initiated. Nothing starts a
// network listener or loads 6.88GB weights simply by opening this test app.
-(void)setupChatUI:(UIViewController *)controller {
 self.chatHistory=[NSMutableArray array];
 self.label.text=@"Jujube / Inkling 2 Mini\n\n親機：iPhone 15\n子機：Pixel 6 Pro（認証済みTLS）\n\n入力欄に質問を記入し、送信してください。\n\n試験版：モデル読み込みに約2分かかります。Pixel側の計算サーバーが起動している必要があります。履歴はこの画面内のみで、アプリを再起動すると消えます。";
 self.label.font=[UIFont systemFontOfSize:16];
 self.label.editable=NO;
 self.label.translatesAutoresizingMaskIntoConstraints=NO;
 self.promptBox=[UITextView new];
 self.promptBox.font=[UIFont systemFontOfSize:17];
 self.promptBox.text=@"こんにちは。あなたは誰ですか？";
 self.promptBox.layer.borderWidth=1;
 self.promptBox.layer.borderColor=UIColor.separatorColor.CGColor;
 self.promptBox.layer.cornerRadius=10;
 self.promptBox.translatesAutoresizingMaskIntoConstraints=NO;
 self.promptBox.accessibilityLabel=@"Inklingへのメッセージ";
 [controller.view addSubview:self.promptBox];
 self.chatButton=[UIButton buttonWithType:UIButtonTypeSystem];
 [self.chatButton setTitle:@"Inklingに送信" forState:UIControlStateNormal];
 self.chatButton.titleLabel.font=[UIFont boldSystemFontOfSize:18];
 [self.chatButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
 self.chatButton.backgroundColor=UIColor.systemBlueColor;
 self.chatButton.layer.cornerRadius=10;
 self.chatButton.translatesAutoresizingMaskIntoConstraints=NO;
 [self.chatButton addTarget:self action:@selector(sendInklingChat) forControlEvents:UIControlEventTouchUpInside];
 [controller.view addSubview:self.chatButton];
 UILayoutGuide *safe=controller.view.safeAreaLayoutGuide;
 [NSLayoutConstraint activateConstraints:@[
  [self.label.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
  [self.label.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
  [self.label.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
  [self.label.bottomAnchor constraintEqualToAnchor:self.chatButton.topAnchor constant:-12],
  [self.chatButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
  [self.chatButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
  [self.chatButton.heightAnchor constraintEqualToConstant:48],
  [self.promptBox.topAnchor constraintEqualToAnchor:self.chatButton.bottomAnchor constant:8],
  [self.promptBox.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
  [self.promptBox.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
  [self.promptBox.heightAnchor constraintEqualToConstant:78],
  [self.promptBox.bottomAnchor constraintEqualToAnchor:controller.view.keyboardLayoutGuide.topAnchor constant:-12]
 ]];
}

-(void)sendInklingChat {
 if (self.chatBusy) return;
 NSString *message=[self.promptBox.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 if (!message.length) {
  self.label.text=[self.label.text stringByAppendingString:@"\n\nメッセージを入力してください。"];
  return;
 }
 if (message.length>240) {
  self.label.text=[self.label.text stringByAppendingString:@"\n\n1回の入力は240文字以内にしてください。"];
  return;
 }
 [self.promptBox resignFirstResponder];
 self.chatBusy=YES;
 self.chatButton.enabled=NO;
 self.chatButton.alpha=0.5;
 NSString *transcript=[self.label.text stringByAppendingFormat:@"\n\nあなた：%@\n\nInkling 2 Mini：読み込みと推論を実行中…",message];
 self.label.text=transcript;
 [self.label scrollRangeToVisible:NSMakeRange(self.label.text.length,0)];
 NSArray *conversation=[self.chatHistory arrayByAddingObject:@{@"role":@"user",@"content":message}];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
  NSString *result=runModel(true,true,conversation);
  NSString *answer=nil;
  NSRange start=[result rangeOfString:@"OUTPUT="];
  NSRange end=[result rangeOfString:@"\nIDS=" options:NSBackwardsSearch];
  if ([result hasPrefix:@"MODE=INKLING_CHAT\n"] &&
      start.location!=NSNotFound && end.location!=NSNotFound &&
      end.location>NSMaxRange(start)) {
   answer=[result substringWithRange:NSMakeRange(NSMaxRange(start),end.location-NSMaxRange(start))];
  }
  if (answer.length) {
   // Store the last local test result for reproducibility; never upload it to any service.
   NSString *file=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/inkling-chat-last-result.txt"];
   [result writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
  dispatch_async(dispatch_get_main_queue(),^{
   if (answer.length) {
    [self.chatHistory addObject:@{@"role":@"user",@"content":message}];
    [self.chatHistory addObject:@{@"role":@"assistant",@"content":answer}];
    // Keep only last two user/assistant pairs within the 1024-token context.
    while(self.chatHistory.count>4) [self.chatHistory removeObjectAtIndex:0];
    self.label.text=[self.label.text stringByReplacingOccurrencesOfString:@"Inkling 2 Mini：読み込みと推論を実行中…"
                                                                 withString:[@"Inkling 2 Mini：" stringByAppendingString:answer]];
    self.promptBox.text=@"";
   } else {
    self.label.text=[self.label.text stringByReplacingOccurrencesOfString:@"Inkling 2 Mini：読み込みと推論を実行中…"
                                                                 withString:[NSString stringWithFormat:@"接続・生成に失敗しました（%@）。Pixel側サーバーの起動を確認してください。",result]];
   }
   [self.label scrollRangeToVisible:NSMakeRange(self.label.text.length,0)];
   self.chatBusy=NO;
   self.chatButton.enabled=YES;
   self.chatButton.alpha=1;
  });
 });
}

-(void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
 if (![scene isKindOfClass:UIWindowScene.class]) return;
 UIWindowScene *windowScene=(UIWindowScene *)scene;
 self.window=[[UIWindow alloc]initWithWindowScene:windowScene];
 UIViewController *v=[UIViewController new];v.view.backgroundColor=UIColor.systemBackgroundColor;
 self.label=[[UITextView alloc]initWithFrame:CGRectInset(v.view.bounds,12,70)];
 self.label.text=@"Jujube Split Test (iPhone 15)\\nIdle; no RPC or network by default.";
 self.label.font=[UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular];
 self.label.editable=NO;self.label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
 [v.view addSubview:self.label];self.window.rootViewController=v;[self.window makeKeyAndVisible];
 NSArray *args=NSProcessInfo.processInfo.arguments;
 BOOL local=[args containsObject:@"--run-local-smoke"],split=[args containsObject:@"--run-split-smoke"];
 BOOL inkling=[args containsObject:@"--run-inkling-split"];
 BOOL chatSmoke=[args containsObject:@"--run-inkling-chat-smoke"];
 BOOL longChatSmoke=[args containsObject:@"--run-inkling-long-chat-smoke"];
 BOOL verifyInklingOnly=[args containsObject:@"--verify-inkling-file-only"];
 NSLog(@"STRATA_SCENE_CONNECTED local=%d split=%d inkling=%d modelCheck=%d",
       local,split,inkling,verifyInklingOnly);
 BOOL exportKey=[args containsObject:@"--export-auth-public"];
 BOOL confirmed=[args containsObject:@"--confirm-pixel-public-key-pinned"];
 static BOOL started=NO;
 if (started) return;
 started=YES;
 if (!(exportKey || local || split || inkling || chatSmoke || longChatSmoke || verifyInklingOnly)) {
   [self setupChatUI:v];
   return;
 }
 if (exportKey) {
   dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
     BOOL exported=ExportBridgePublicKey();
     dispatch_async(dispatch_get_main_queue(), ^{
       self.label.text=exported?@"Exported Documents/auth-client-public.bin":@"FAIL: see Documents/bridge-status.txt";
     });
   });
   return;
 }
 if (verifyInklingOnly) {
   dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
     // This mode NEVER starts the TLS listener, registers an RPC backend,
     // loads model weights in RAM or executes inference.
     NSString *model=verifiedInklingGGUF();
     NSString *result=model?
       [NSString stringWithFormat:@"INKLING_MODEL_SHA256_OK\\nFILE=%@\\nIPHONE_PHYSICAL_RAM_BYTES=%llu",
         model,(unsigned long long)NSProcessInfo.processInfo.physicalMemory]:
       @"FAIL: Inkling GGUF not present or checksum mismatch";
     NSString *out=[NSHomeDirectory() stringByAppendingPathComponent:
       @"Documents/inkling-weight-check.txt"];
     [result writeToFile:out atomically:YES encoding:NSUTF8StringEncoding error:nil];
     dispatch_async(dispatch_get_main_queue(), ^{self.label.text=result;});
   });
   return;
 }
 if ((int)local + (int)split + (int)inkling + (int)chatSmoke + (int)longChatSmoke + (int)verifyInklingOnly > 1) {
   self.label.text=@"FAIL: choose one smoke mode";
   return;
 }
 if ((split || inkling || chatSmoke || longChatSmoke) && !confirmed) {
   BridgeAudit(@"FAIL split smoke requires supervisor confirmation of Pixel public-key pinning");
   self.label.text=@"Split smoke requires --confirm-pixel-public-key-pinned";
   return;
 }
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
   NSString *longQuestion=@"あなたはJujubeというスマートフォン向けのローカルAIです。iPhoneとPixelが協力して一つのモデルを実行します。三人寄れば文殊の知恵という考え方について、日本語で簡潔に説明してください。";
   NSArray *conversation=(chatSmoke || longChatSmoke)?
       @[@{@"role":@"user",@"content":longChatSmoke?longQuestion:@"こんにちは。あなたは誰ですか？"}]:nil;
   NSString *result=runModel(split || inkling || chatSmoke || longChatSmoke,inkling || chatSmoke || longChatSmoke,conversation);
   NSLog(@"STRATA_PROBE_RESULT %@",result);
   if ((split || inkling || chatSmoke || longChatSmoke) && [result hasPrefix:@"FAIL"]) BridgeAudit(result);
   NSString *output=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/probe-result.txt"];
   BOOL saved=[result writeToFile:output atomically:YES encoding:NSUTF8StringEncoding error:nil];
   NSLog(@"STRATA_PROBE_FILE_SAVED %d",saved);
   dispatch_async(dispatch_get_main_queue(),^{self.label.text=result;});
 });
}
@end
@interface ProbeApp:UIResponder<UIApplicationDelegate>
@end
@implementation ProbeApp
-(BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
 NSLog(@"STRATA_APPLICATION_LAUNCHED");
 return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeApp.class));}}
