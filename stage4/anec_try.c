// Own test harness: loads ANECompiler, calls exported ANECCompile with a TargetArchitecture option.
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <Block.h>
typedef int (*Fn)(CFDictionaryRef, CFDictionaryRef, void (^)(void *));
static CFStringRef S(const char *s){return CFStringCreateWithCString(0,s,kCFStringEncodingUTF8);}
int main(int argc,char**argv){
  // argv: dir netplist arch outname [weightfile]
  void *h=dlopen("/System/Library/PrivateFrameworks/ANECompiler.framework/ANECompiler",RTLD_NOW);
  if(!h){printf("dlopen fail %s\n",dlerror());return 2;}
  Fn f=(Fn)dlsym(h,"ANECCompile");
  printf("ANECCompile=%p\n",f); if(!f) return 3;
  const char *dir=argv[1];
  char d2[1024]; snprintf(d2,sizeof d2,"%s/",dir);
  CFMutableDictionaryRef net=CFDictionaryCreateMutable(0,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(net,S(getenv("NK1")?getenv("NK1"):"NetworkPlistName"),S(argv[2]));
  CFDictionarySetValue(net,S(getenv("NK2")?getenv("NK2"):"NetworkPlistPath"),S(d2));
  if(argc>5){CFDictionarySetValue(net,S("WeightFileName"),S(argv[5]));CFDictionarySetValue(net,S("WeightFilePath"),S(d2));}
  CFTypeRef arr[1]={net};
  CFArrayRef nets=CFArrayCreate(0,arr,1,&kCFTypeArrayCallBacks);
  CFMutableDictionaryRef in=CFDictionaryCreateMutable(0,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(in,S("InputNetworks"),nets);
  CFDictionarySetValue(in,S("OutputFileName"),S(argv[4]));
  CFDictionarySetValue(in,S("OutputFilePath"),S(d2));
  CFMutableDictionaryRef opt=CFDictionaryCreateMutable(0,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(opt,S("TargetArchitecture"),S(argv[3]));
  CFShow(in);CFShow(opt);
  int r=f(in,opt,^(void*x){printf("callback arg=%p\n",x);});
  printf("ANECCompile returned %d\n",r);
  return 0;
}
