# Live2D Model Assets

Place your Live2D model folder here before running the example.

## Expected structure

```
assets/models/
└── YourModel/
    ├── YourModel.model3.json   ← main settings file
    ├── YourModel.moc3          ← model data
    ├── YourModel.physics3.json ← physics (optional)
    ├── YourModel.pose3.json    ← pose (optional)
    ├── textures/
    │   └── texture_00.png
    └── motions/
        ├── idle_01.motion3.json
        └── ...
```

## pubspec.yaml

Add the model folder to your assets section:

```yaml
flutter:
  assets:
    - assets/models/YourModel/
    - assets/models/YourModel/textures/
    - assets/models/YourModel/motions/
```

## Free test models

Download from the Live2D official sample data:
https://www.live2d.com/en/learn/sample/
