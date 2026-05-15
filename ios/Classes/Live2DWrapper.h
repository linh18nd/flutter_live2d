#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * ObjC wrapper around the C++ Live2D layer.
 *
 * One instance per Live2D view. All methods must be called on the GL/render
 * thread (the main thread for the GLKView setup we use).
 *
 * The Cubism Framework is initialized lazily the first time any wrapper is
 * created and torn down when the last one is disposed.
 */
@interface Live2DWrapper : NSObject

- (instancetype)init;

- (void)dispose;

- (void)onSurfaceCreated;
- (void)onSurfaceChangedWidth:(int)width height:(int)height
    NS_SWIFT_NAME(onSurfaceChanged(width:height:));
- (void)onDrawFrame;

- (BOOL)loadModelWithDir:(NSString *)modelDir fileName:(NSString *)fileName
    NS_SWIFT_NAME(loadModel(modelDir:fileName:));
- (void)unloadModel;

/// Call with current GL context and after `GLKView` `bindDrawable` when
/// `_pendingGLRenderer` may be set (drawable was not ready at load/resize).
- (void)tryCompletePendingRendererInstall;

/// If the default framebuffer has no color attachment but a Cubism renderer
/// still exists (stale RB after platform view rebuild), delete it and defer
/// reinstall until the drawable is valid again.
- (void)onFramebufferColorAttachmentMissing;


- (void)touchBeganAtX:(float)x y:(float)y
    NS_SWIFT_NAME(touchBegan(x:y:));
- (void)touchMovedAtX:(float)x y:(float)y
    NS_SWIFT_NAME(touchMoved(x:y:));
- (void)touchEndedAtX:(float)x y:(float)y
    NS_SWIFT_NAME(touchEnded(x:y:));

- (void)startMotionGroup:(NSString *)group index:(int)index priority:(int)priority
    NS_SWIFT_NAME(startMotion(group:index:priority:));
- (void)setExpressionAtIndex:(int)index
    NS_SWIFT_NAME(setExpression(index:));
- (void)setParameterWithId:(NSString *)parameterId value:(float)value
    NS_SWIFT_NAME(setParameter(parameterId:value:));

/// Sets the playback speed multiplier for motions.
/// 1.0 = normal speed, 2.0 = double speed, 0.5 = half speed, 0.0 = paused.
/// Physics, eye-blink and expressions are NOT affected.
- (void)setMotionSpeed:(float)speed
    NS_SWIFT_NAME(setMotionSpeed(_:));

@end

NS_ASSUME_NONNULL_END
