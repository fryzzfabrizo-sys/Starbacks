//file icons.mm
#import "icons.h"
#import <UIKit/UIKit.h>

UIImage *FloatButtonIcon(void) {
    // 👇 Dán chuỗi Base64 ảnh của bạn vào đây (giữa hai dấu ngoặc kép)
    static NSString *base64String = @"";
    
    // Kiểm tra nếu chuỗi rỗng -> fallback
    if (base64String.length == 0) {
        NSLog(@"[FloatButtonIcon] ⚠️ Chưa có Base64, dùng fallback");
        if (@available(iOS 13.0, *)) {
            UIImage *fallback = [UIImage systemImageNamed:@"gearshape.fill"];
            return [fallback imageWithTintColor:[UIColor grayColor] 
                                   renderingMode:UIImageRenderingModeAlwaysOriginal];
        }
        return nil;
    }
    
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64String
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
    
    if (!data) {
        NSLog(@"[FloatButtonIcon] ❌ Lỗi: Không thể decode Base64");
        return nil;
    }
    
    UIImage *image = [UIImage imageWithData:data];
    if (!image) {
        NSLog(@"[FloatButtonIcon] ❌ Lỗi: Dữ liệu ảnh không hợp lệ");
        return nil;
    }
    
    return image;
}