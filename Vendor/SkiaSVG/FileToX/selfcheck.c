#include "CNativeSvg.h"
#include <assert.h>
#include <string.h>
static int after_parse(void *context) {
    int *calls = context;
    return ++*calls >= 2;
}
static int during_playback(void *context) {
    int *calls = context;
    return ++*calls >= 4;
}
static int once_during_playback(void *context) {
    int *calls = context;
    return ++*calls == 4;
}
int main(void) {
    const char *xml="<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'><rect width='2' height='2' fill='red'/></svg>";
    unsigned char pixels[20];
    memset(pixels,19,sizeof(pixels));
    assert(ftx_svg_render(xml,8*1024*1024+1,2,2,1,2,2,pixels,16,0,0)==1);
    assert(ftx_svg_render(xml,strlen(xml),2,2,1,2,2,pixels,15,0,0)==1);
    assert(ftx_svg_render(xml,strlen(xml),2,2,1,16385,2,pixels,16,0,0)==1);
    assert(ftx_svg_render(xml,strlen(xml),2,2,1,1,2,pixels,16,0,0)==1);
    assert(ftx_svg_render("bad XML",7,2,2,1,2,2,pixels,16,0,0)==2);
    int calls=0;
    assert(ftx_svg_render(xml,strlen(xml),2,2,1,2,2,pixels,16,after_parse,&calls)==3);
    assert(calls==2);
    for(int i=0;i<20;i++) assert(pixels[i]==19);
    calls=0;
    assert(ftx_svg_render(xml,strlen(xml),2,2,1,2,2,pixels,16,during_playback,&calls)==3);
    assert(calls>=4);
    calls=0;
    assert(ftx_svg_render(xml,strlen(xml),2,2,1,2,2,pixels,16,once_during_playback,&calls)==3);
    assert(calls==4);
    for(int i=16;i<20;i++) assert(pixels[i]==19);
    assert(ftx_svg_render(xml,strlen(xml),2,2,1,2,2,pixels,16,0,0)==0);
    for(int i=0;i<16;i+=4) { assert(pixels[i]==255);assert(pixels[i+1]==0);assert(pixels[i+2]==0);assert(pixels[i+3]==255); }
    for(int i=16;i<20;i++) assert(pixels[i]==19);
    return 0;
}
