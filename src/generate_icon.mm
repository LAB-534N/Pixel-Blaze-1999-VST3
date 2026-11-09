#import <Cocoa/Cocoa.h>
#include <cmath>

int main(int argc, char** argv) {
    @autoreleasepool {
        const char* outPath = (argc > 1) ? argv[1] : "build/icon_1024.png";
        int size = 1024;
        NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:size
                          pixelsHigh:size
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSCalibratedRGBColorSpace
                         bytesPerRow:0
                        bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];

        // Outer macOS squircle background (NES Dark Charcoal / Crimson border)
        CGRect bgRect = CGRectMake(56, 56, 912, 912);
        CGPathRef bgPath = CGPathCreateWithRoundedRect(bgRect, 196, 196, NULL);
        CGContextAddPath(ctx, bgPath);
        CGContextClip(ctx);

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat bgCols[] = { 0.12, 0.13, 0.16, 1.0,  0.22, 0.23, 0.27, 1.0 };
        CGGradientRef grad = CGGradientCreateWithColorComponents(cs, bgCols, NULL, 2);
        CGContextDrawLinearGradient(ctx, grad, CGPointMake(512, 968), CGPointMake(512, 56), 0);
        CGGradientRelease(grad);

        // NES Light Gray Top Shell Stripe
        CGContextSetRGBFillColor(ctx, 0.80, 0.80, 0.82, 1.0);
        CGContextFillRect(ctx, CGRectMake(56, 680, 912, 288));

        // Crimson Red Accent Stripe
        CGContextSetRGBFillColor(ctx, 0.90, 0.16, 0.18, 1.0);
        CGContextFillRect(ctx, CGRectMake(56, 650, 912, 30));

        // Center Glowing CRT Screen
        CGRect crtRect = CGRectMake(164, 340, 696, 270);
        CGPathRef crtPath = CGPathCreateWithRoundedRect(crtRect, 28, 28, NULL);
        CGContextAddPath(ctx, crtPath);
        CGContextSetRGBFillColor(ctx, 0.04, 0.09, 0.07, 1.0);
        CGContextFillPath(ctx);
        CGContextAddPath(ctx, crtPath);
        CGContextSetRGBStrokeColor(ctx, 0.15, 0.96, 0.62, 0.95);
        CGContextSetLineWidth(ctx, 12.0);
        CGContextStrokePath(ctx);
        CGPathRelease(crtPath);

        // Stair-stepped 8-Bit Pulse/Square Waveform inside CRT
        CGContextSetRGBStrokeColor(ctx, 0.15, 0.96, 0.62, 1.0);
        CGContextSetLineWidth(ctx, 20.0);
        CGContextBeginPath(ctx);
        CGFloat wx = 210;
        CGFloat wyHigh = 540, wyLow = 410;
        CGContextMoveToPoint(ctx, wx, wyLow);
        for (int i = 0; i < 4; ++i) {
            CGContextAddLineToPoint(ctx, wx + 75, wyLow);
            CGContextAddLineToPoint(ctx, wx + 75, wyHigh);
            CGContextAddLineToPoint(ctx, wx + 150, wyHigh);
            CGContextAddLineToPoint(ctx, wx + 150, wyLow);
            wx += 150;
        }
        CGContextStrokePath(ctx);

        // Left Physical D-Pad on Icon
        CGContextSetRGBFillColor(ctx, 0.78, 0.78, 0.80, 1.0);
        CGContextFillRect(ctx, CGRectMake(170, 165, 180, 60));
        CGContextFillRect(ctx, CGRectMake(230, 105, 60, 180));

        // Right Crimson A & B Buttons on Icon
        CGContextSetRGBFillColor(ctx, 0.90, 0.16, 0.18, 1.0);
        CGContextFillEllipseInRect(ctx, CGRectMake(590, 120, 110, 110));
        CGContextFillEllipseInRect(ctx, CGRectMake(730, 165, 110, 110));

        // Outer border
        CGContextAddPath(ctx, bgPath);
        CGContextSetRGBStrokeColor(ctx, 0.90, 0.16, 0.18, 0.90);
        CGContextSetLineWidth(ctx, 18.0);
        CGContextStrokePath(ctx);

        CGPathRelease(bgPath);
        CGColorSpaceRelease(cs);
        [NSGraphicsContext restoreGraphicsState];

        NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:[NSString stringWithUTF8String:outPath] atomically:YES];
    }
    return 0;
}
