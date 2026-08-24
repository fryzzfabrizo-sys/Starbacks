#import "esp.h"
#import "../Core/GameLogic.h"
#import "mahoa.h"
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <cmath>
#include <unordered_map>

UIFont *VietnameseFontForLayer(CGFloat size) {
    static UIFont *cachedFont = nil;
    if (!cachedFont) {
        UIFont *f = [UIFont fontWithName:NSSENCRYPT("GFF-Latin-Bold") size:size];
        if (!f) f = [UIFont systemFontOfSize:size];
        UIFontDescriptor *boldDesc = [f.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
        UIFont *boldFont = [UIFont fontWithDescriptor:boldDesc size:size];
        cachedFont = boldFont ?: [UIFont boldSystemFontOfSize:size];
    }
    return cachedFont;
}

static inline CGFloat SnapPixel(CGFloat v) {
    return roundf(v * 2.0f) * 0.5f;
}
static inline CGPoint SnapPoint(CGPoint p) {
    return CGPointMake(SnapPixel(p.x), SnapPixel(p.y));
}
static inline CGRect SnapRect(CGRect r) {
    return CGRectIntegral(r);
}

static std::unordered_map<uint64_t, float> gSmoothedBoxHeight;
static inline float SmoothedBoxHeight(uint64_t pawn, float newH) {
    auto it = gSmoothedBoxHeight.find(pawn);
    if (it == gSmoothedBoxHeight.end()) {
        gSmoothedBoxHeight[pawn] = newH;
        return newH;
    }
    float smoothed = it->second * 0.75f + newH * 0.25f;
    it->second = smoothed;
    return smoothed;
}

static inline void ESPAddLine(CGMutablePathRef path, CGPoint p1, CGPoint p2) {
    if (!path) return;
    p1 = SnapPoint(p1);
    p2 = SnapPoint(p2);
    CGPathMoveToPoint(path, NULL, p1.x, p1.y);
    CGPathAddLineToPoint(path, NULL, p2.x, p2.y);
}

static inline void ESPAddCircle(CGMutablePathRef path, CGPoint center, CGFloat radius) {
    if (!path) return;
    center = SnapPoint(center);
    radius = SnapPixel(radius);
    CGRect rect = CGRectMake(center.x - radius, center.y - radius, radius * 2.0f, radius * 2.0f);
    CGPathAddEllipseInRect(path, NULL, rect);
}

static inline void ESPAddFullRect(CGMutablePathRef path, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    if (!path || w < 1.0f || h < 1.0f) return;
    CGRect rect = SnapRect(CGRectMake(x, y, w, h));
    CGPathAddRect(path, NULL, rect);
}

static inline void ESPAddCornerBox(CGMutablePathRef path,
                                   CGFloat x,
                                   CGFloat y,
                                   CGFloat w,
                                   CGFloat h)
{
    if (!path || w < 1.0f || h < 1.0f) return;

    CGFloat cornerW = w * 0.25f;
    CGFloat cornerH = h * 0.20f;

    // Top Left
    ESPAddLine(path, CGPointMake(x, y),
                     CGPointMake(x + cornerW, y));
    ESPAddLine(path, CGPointMake(x, y),
                     CGPointMake(x, y + cornerH));

    // Top Right
    ESPAddLine(path, CGPointMake(x + w, y),
                     CGPointMake(x + w - cornerW, y));
    ESPAddLine(path, CGPointMake(x + w, y),
                     CGPointMake(x + w, y + cornerH));

    // Bottom Left
    ESPAddLine(path, CGPointMake(x, y + h),
                     CGPointMake(x + cornerW, y + h));
    ESPAddLine(path, CGPointMake(x, y + h),
                     CGPointMake(x, y + h - cornerH));

    // Bottom Right
    ESPAddLine(path, CGPointMake(x + w, y + h),
                     CGPointMake(x + w - cornerW, y + h));
    ESPAddLine(path, CGPointMake(x + w, y + h),
                     CGPointMake(x + w, y + h - cornerH));
}

BOOL RenderFOVCirclePath(
    CGMutablePathRef path,
    float viewWidth,
    float viewHeight,
    BOOL aimbotEnabled,
    float fovRadius
) {
    if (!path) return NO;
    if (!aimbotEnabled || fovRadius <= 0) return NO;
    if (viewWidth < 10 || viewHeight < 10) return NO;

    float cx = viewWidth / 2.0f;
    float cy = viewHeight / 2.0f;
    float d  = fovRadius * 2.0f;
    CGPathAddEllipseInRect(path, NULL, CGRectMake(cx - fovRadius, cy - fovRadius, d, d));
    return YES;
}

void RenderESPForPawn(
    ESPGeometryBuffers *buffers,
    ESPAddTextCallback textCallback,
    void *callbackContext,
    uint64_t PawnObject,
    int CurHP,
    float dis,
    float *matrix,
    float layerWidth,
    float layerHeight,
    float matrixVpWidth,
    float matrixVpHeight
) {
    if (dis > 400.0f || !buffers || !matrix) return;
    if (!PawnObject || !isVaildPtr(PawnObject)) return;

    Vector3 HeadPos = getPositionExt(getHead(PawnObject));
    Vector3 pos = getPositionExt(getHip(PawnObject)); 
    if(pos == Vector3(0,0,0)) return; 
    Vector3 HeadTop = pos; HeadTop.y += 0.8f; 

    Vector3 RightToePos = pos; RightToePos.y -= 0.7f; 

    Vector3 w2sHead = WorldToScreenLayer(HeadTop, matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight); 

    Vector3 w2sToe = WorldToScreenLayer(RightToePos, matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight); 

    if (w2sHead.z < 0.001f || w2sToe.z < 0.001f) return; 

    const float margin = layerWidth * 0.6f; if (w2sHead.x < -margin || w2sHead.x > layerWidth + margin || w2sHead.y < -margin || w2sHead.y > layerHeight + margin) return; 

    Vector3 wHead = WorldToScreenLayer(HeadPos, matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight); 

    float headX = SnapPixel(w2sHead.x); float headY = SnapPixel(w2sHead.y); 

    float rawBoxHeight = fabsf(w2sHead.y - w2sToe.y); 

    float boxHeight = SmoothedBoxHeight(PawnObject, rawBoxHeight); 

    boxHeight = roundf(boxHeight / 2.0f) * 2.0f; 

    // 🟢 SỬA: Thu nhỏ box từ 0.5f xuống 0.35f
    float boxWidth = boxHeight * 0.40f; 

    boxWidth = roundf(boxWidth);

    float x = roundf(headX - boxWidth * 0.5f); 

    float y = roundf(headY); 

    // ─── BONE ───────────────────
    
    if (isBone) {
        Vector3 HipPos      = getPositionExt(getHip(PawnObject));
        Vector3 LeftToePos  = getPositionExt(getLeftAnkle(PawnObject));
        Vector3 L_Ankle     = getPositionExt(getLeftAnkle(PawnObject));
        Vector3 R_Ankle     = getPositionExt(getRightAnkle(PawnObject));
        Vector3 L_ForeArm   = getPositionExt(getLeftElbow(PawnObject));
        Vector3 R_ForeArm   = getPositionExt(getRightElbow(PawnObject));
        Vector3 L_Hand      = getPositionExt(getLeftHand(PawnObject));
        Vector3 R_Hand      = getPositionExt(getRightHand(PawnObject));

        Vector3 wHip  = WorldToScreenLayer(HipPos,  matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
        Vector3 wLE = WorldToScreenLayer(L_ForeArm,  matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
        Vector3 wRE = WorldToScreenLayer(R_ForeArm,  matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
        Vector3 wLH = WorldToScreenLayer(L_Hand,     matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
        Vector3 wRH = WorldToScreenLayer(R_Hand,     matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
        Vector3 wLA = WorldToScreenLayer(L_Ankle,    matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
        Vector3 wRA = WorldToScreenLayer(R_Ankle,    matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
        Vector3 wLT = WorldToScreenLayer(LeftToePos, matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);
        Vector3 wRT = WorldToScreenLayer(RightToePos,matrix, matrixVpWidth, matrixVpHeight, layerWidth, layerHeight);

        CGPoint pHead = CGPointMake(wHead.x, wHead.y);
        CGPoint pHip  = CGPointMake(wHip.x,  wHip.y);
        CGPoint pNeck = CGPointMake(
            pHead.x + (pHip.x - pHead.x) * 0.15f,
            pHead.y + (pHip.y - pHead.y) * 0.15f
        );
        CGPoint pLE = CGPointMake(wLE.x, wLE.y);
        CGPoint pRE = CGPointMake(wRE.x, wRE.y);
        CGPoint pLS = CGPointMake(
            pNeck.x + (pLE.x - pNeck.x) * 0.3f,
            pNeck.y + (pLE.y - pNeck.y) * 0.3f
        );
        CGPoint pRS = CGPointMake(
            pNeck.x + (pRE.x - pNeck.x) * 0.3f,
            pNeck.y + (pRE.y - pNeck.y) * 0.3f
        );
        CGPoint pLH = CGPointMake(wLH.x, wLH.y);
        CGPoint pRH = CGPointMake(wRH.x, wRH.y);
        CGPoint pLK = CGPointMake(
            pHip.x + (wLA.x - pHip.x) * 0.45f,
            pHip.y + (wLA.y - pHip.y) * 0.45f
        );
        CGPoint pRK = CGPointMake(
            pHip.x + (wRA.x - pHip.x) * 0.45f,
            pHip.y + (wRA.y - pHip.y) * 0.45f
        );
        CGPoint pLA = CGPointMake(wLA.x, wLA.y);
        CGPoint pRA = CGPointMake(wRA.x, wRA.y);
        CGPoint pLT = CGPointMake(wLT.x, wLT.y);
        CGPoint pRT = CGPointMake(wRT.x, wRT.y);

        // 🟢 SỬA: Bỏ hình tròn, vẽ đoạn thẳng từ Neck lên Head
        ESPAddLine(buffers->bonePath, pNeck, pHead);

        ESPAddLine(buffers->bonePath, pNeck, pHip);
        ESPAddLine(buffers->bonePath, pNeck, pLS);
        ESPAddLine(buffers->bonePath, pLS,   pLE);
        ESPAddLine(buffers->bonePath, pLE,   pLH);
        ESPAddLine(buffers->bonePath, pNeck, pRS);
        ESPAddLine(buffers->bonePath, pRS,   pRE);
        ESPAddLine(buffers->bonePath, pRE,   pRH);
        ESPAddLine(buffers->bonePath, pHip, pLK);
        ESPAddLine(buffers->bonePath, pLK,  pLA);
        ESPAddLine(buffers->bonePath, pLA,  pLT);
        ESPAddLine(buffers->bonePath, pHip, pRK);
        ESPAddLine(buffers->bonePath, pRK,  pRA);
        ESPAddLine(buffers->bonePath, pRA,  pRT);

        buffers->boneDirty = true;
    }
    

    // ─── SNAPLINE ─────────────────────────────────────────────
    CGPoint lineStart = CGPointMake(
        layerWidth / 2.0f,
        0.0f
    );

    CGPoint enemyHead = CGPointMake(
        x + boxWidth * 0.5f,
        y
    );

    bool isKnocked = get_IsKnockedDown(PawnObject);

    BOOL isBot = get_IsBot(PawnObject);
    if(isLine){

        if(isKnocked) {

            ESPAddLine(buffers->lineKnockPath,
                       lineStart,
                       enemyHead);
            buffers->lineKnockDirty = true;

        }else if (isBot) {
            ESPAddLine(buffers->lineBotPath,
                       lineStart,
                       enemyHead);
            buffers->lineBotDirty = true;

        }else{

            ESPAddLine(buffers->linePlayerPath,
                       lineStart,
                       enemyHead);
            buffers->linePlayerDirty = true;
        }
    }
    // ─── BOX ──────────────────────────────────────────────────

    if (isBox) {

        if(box == 0){

            if(isKnocked) { 

                ESPAddFullRect(buffers->boxKnockPath, x, y, boxWidth, boxHeight);
                buffers->boxKnockDirty = true;

            }else if (isBot) {
                ESPAddFullRect(buffers->boxBotPath, x, y, boxWidth, boxHeight);
                buffers->boxBotDirty = true; 

            }else{
                ESPAddFullRect(buffers->boxPlayerPath, x, y, boxWidth, boxHeight);
                buffers->boxPlayerDirty = true;
            }
        }else if (box == 1){

            if(isKnocked) { 

                ESPAddCornerBox(buffers->boxKnockPath, x, y, boxWidth, boxHeight);
                buffers->boxKnockDirty = true;

            }else if (isBot) {
                ESPAddCornerBox(buffers->boxBotPath, x, y, boxWidth, boxHeight);
                buffers->boxBotDirty = true; 

            }else{
                ESPAddCornerBox(buffers->boxPlayerPath, x, y, boxWidth, boxHeight);
                buffers->boxPlayerDirty = true;
            }

        }
    }

    // ─── TỌA ĐỘ TEXT ────────────────────
    const CGFloat kNameLineH = 12.0f;
    const CGFloat kNameY     = y - kNameLineH - 2.0f; 
    const CGFloat kDistY     = y + boxHeight + 3.0f;

    CGFloat   namePartWidth = 0.0f;
    NSString *displayName   = nil;

    // 🟢 SỬA: Chỉ tính toán tên nếu bật isName
    if (isName) {
        NSString *Name = (isEspBot && get_IsBot(PawnObject)) ? NSSENCRYPT("BOT") : GetNickName(PawnObject);
        
        // Fallback nếu Name rỗng hoặc nil (fix lỗi không hiện tên)
        if (Name == nil || Name.length == 0) {
            Name = isBot ? NSSENCRYPT("BOT") : NSSENCRYPT("Player");
        }
        
        if (Name.length > 0) {
            displayName = Name;
            namePartWidth = (CGFloat)(Name.length * 5.5f);
            if (namePartWidth > 120.0f) {
                displayName = [NSString stringWithFormat:@"%@…", [Name substringToIndex:fmin(Name.length, 12)]];
                namePartWidth = (CGFloat)(displayName.length * 5.5f);
            }
        }
    }

    CGFloat totalTextWidth = (isName ? namePartWidth : 0);
    CGFloat nameX = headX - totalTextWidth * 0.5f;

    // ─── NAME text ───────────────────
    // 🟢 SỬA: Chỉ hiện tên khi bật isName (đã fix fallback ở trên)
    if (isName && textCallback && displayName.length > 0) {
        BOOL isBot = (isEspBot && get_IsBot(PawnObject));
        UIColor *textColor = isBot ? [UIColor redColor] : [UIColor whiteColor];
        textCallback(callbackContext, displayName,
                     CGRectMake(nameX, kNameY, namePartWidth, kNameLineH),
                     textColor, 9.0f, YES);
    }

    // 🟢 SỬA: COMMENT dòng hiện số HP trên đầu địch
    /*
    if (isHealth && textCallback) {
        NSString *hpString = [NSString stringWithFormat:@"%d", CurHP];
        UIColor *hpColor;
        if (CurHP > 100) hpColor = [UIColor colorWithRed:0.2f green:0.85f blue:0.3f alpha:1.0f];
        else             hpColor = [UIColor yellowColor];
        
        textCallback(callbackContext, hpString,
                     CGRectMake(nameX, kNameY, hpPartWidth, kNameLineH),
                     hpColor, 9.0f, YES);
    }
    */

    // ─── HEALTH BAR ──────────────────────────────────────────
    if (isHealth) {
        int MaxHP = get_MaxHP(PawnObject);
        if (MaxHP > 0) {
            float healthRatio = (float)CurHP / (float)MaxHP;
            if (healthRatio < 0.0f) healthRatio = 0.0f;
            if (healthRatio > 1.0f) healthRatio = 1.0f;

            // 🟢 SỬA: Tách xa hơn, dày hơn, thêm viền đen
            const CGFloat barWidth = 3.0f;
            const CGFloat barGap   = 4.0f;
            const CGFloat borderThick = 1.0f;
            
            CGFloat barX      = x - barGap - barWidth;
            CGFloat barTop    = y;
            CGFloat barBottom = y + boxHeight;
            CGFloat barHeight = barBottom - barTop;
            CGFloat filledH   = roundf(barHeight * (CGFloat)healthRatio);
            CGFloat filledTop = barBottom - filledH;

            // Viền đen bao quanh
            CGRect borderRect = SnapRect(CGRectMake(barX - borderThick, barTop - borderThick,
                                                     barWidth + borderThick * 2.0f, barHeight + borderThick * 2.0f));
            CGPathAddRect(buffers->hpBackgroundPath, NULL, borderRect);
            buffers->hpBackgroundDirty = true;

            // Phần thanh máu đầy (màu tự động đổi dựa trên HP)
            if (filledH > 0.5f) {
                CGRect fillRect = SnapRect(CGRectMake(barX, filledTop, barWidth, filledH));
                CGPathAddRect(buffers->hpFillPath, NULL, fillRect);
                buffers->hpFillDirty = true;
            }
        }
    }

    // ─── DISTANCE ────────────────────────────────────────────
    if (isDis && textCallback) {
        NSString *distString = [NSString stringWithFormat:@"[%2.0fM]", dis];
        CGFloat distWidth = (CGFloat)(distString.length * 5.5f);
        CGFloat distX = headX - (distWidth * 0.5f);
        
        CGRect frame = CGRectMake(distX, kDistY, distWidth, kNameLineH);
        textCallback(callbackContext, distString, frame, [UIColor whiteColor], 9.0f, YES);
    }
}