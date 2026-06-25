# L2 YOLOv8-nano UI detector — model asset

The L2 detection layer (`com.waylo.ml.YOLOv8Detector`) loads a TensorFlow Lite
model from this assets folder:

- `ui_detector.tflite`  ← **not yet committed** (produced by training, see below)
- `ui_labels.txt`       ← class names (already committed)

Until `ui_detector.tflite` is added, L2 is automatically **skipped** at runtime
(`YOLOv8Detector.create()` returns null). The pipeline still runs L0 → L1 → L3,
so the app builds and works without it.

## Producing the model

1. Download the RICO dataset (~66k Android UI screenshots) from
   interactionmining.org/rico.
2. Auto-label screenshots with ScreenAI (Colab) into YOLO format. Classes must
   match `ui_labels.txt`:
   `BUTTON, FAB, TEXT_INPUT, NAV_ITEM, APP_ICON, TOGGLE, CHECKBOX, DROPDOWN, IMAGE, TEXT_LABEL`
3. Fine-tune:
   ```python
   from ultralytics import YOLO
   model = YOLO('yolov8n.pt')
   model.train(data='rico_ui.yaml', epochs=50, imgsz=640, batch=32, device='cuda')
   model.export(format='tflite', int8=True)   # ~6 MB
   ```
4. Drop the exported `.tflite` here as `ui_detector.tflite`.

## Expected model I/O

- Input:  `[1, 640, 640, 3]`, FLOAT32 (0..1) or UINT8 — both handled.
- Output: ultralytics YOLOv8 head `[1, 4+numClasses, 8400]` (xywh + class scores).

The detector decodes boxes, applies confidence (0.25) + NMS (0.45), then the
guidance pipeline picks the box whose class best matches the step's
`elementType` and screen region.
