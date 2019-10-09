//
//  ViewController.swift
//  FaceDataRecorder
//
//  Created by Elisha Hung on 2017/11/12.
//  Copyright © 2017 Elisha Hung. All rights reserved.
//
//  http://www.elishahung.com/

import UIKit
import ARKit
import SceneKit
import Foundation

class ViewController: UIViewController, ARSessionDelegate {
    
    @IBOutlet weak var sceneView: ARSCNView!  // Main view
    @IBOutlet weak var captureButton: UIButton!  // Start capture process
    @IBOutlet weak var settingButton: UIButton!  // Record fps setting or server ip setting
    @IBOutlet weak var infoText: UILabel!  // Simple capture information
    
    private let ini = UserDefaults.standard  // Store user setting
    
    var session: ARSession {
        return sceneView.session
    }
    
    var isCapturing = false {
        didSet {
            settingButton.isEnabled = !isCapturing
        }
    }
    
    var captureMode = CaptureMode.record {
        didSet {
            refreshInfo()
            ini.set(captureMode == .record, forKey: "mode")
        }
    }
    
    // Record mode's properties
    var fps = 24.0 {
        didSet {
            fps = min(max(fps, 1.0), 60.0)
            ini.set(fps, forKey: "fps")
        }
    }
    var fpsTimer: Timer!
    var captureData: [CaptureData]!
    var currentCaptureFrame = 0
    var folderPath : URL!
    
    // Queue varibales
    private let saveQueue = DispatchQueue.init(label: "com.eliWorks.faceCaptureX")
    private let dispatchGroup = DispatchGroup()
    
    // Init
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let lastFps = ini.double(forKey: "fps")
        if lastFps != 0 {
            fps = lastFps
        }
        captureMode = .record
       
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = false  // for performance
        
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    // View actions and initialize tracking here
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        initTracking()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCapture()
        session.pause()
    }
    
    // AR session delegate
    func session(_ session: ARSession, didFailWithError error: Error) {
        stopCapture()
        DispatchQueue.main.async {
            self.initTracking()
        }
    }
    func sessionWasInterrupted(_ session: ARSession) {
        return
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async {
            self.initTracking()
        }
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
    }
    
    // UI Actions
    @IBAction func pressCaptureButton(_ sender: Any) {
        // Stop Capture
        if isCapturing {
            stopCapture()
        }else{
        // Start Capture
            let text = "Recording"
            captureButton.setTitle(text, for: .normal)
            
            startCapture()
        }
    }
    
    @IBAction func settingPressed(_ sender: Any) {
        popRecordSetting()
    }
    
    func refreshInfo() {
        infoText.text = "Record > \(fps) FPS"
    }
    
    // Capture Process
    func initTracking() {
        guard ARFaceTrackingConfiguration.isSupported else { return }
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    
    func startCapture() { // Where capture button pressed, streaming or recording
        
        refreshInfo()
        
        // Record Mode : Clean record data, create save folder, use timer to record for stable fps
        captureData = []
        currentCaptureFrame = 0
        let documentPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        folderPath = documentPath.appendingPathComponent(folderName())
        try? FileManager.default.createDirectory(atPath: folderPath.path, withIntermediateDirectories: true, attributes: nil)
        isCapturing = true
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1/fps, repeats: true, block: {(timer) -> Void in
            self.recordData()
        })

    }
    
    func stopCapture() { // Stop Capture Process
        isCapturing = false

        // Record Mode : Turn off timer, convert capture data to string and save into documentary
        fpsTimer.invalidate()
        let fileName = folderPath.appendingPathComponent("faceData.txt")
        let data = captureData.map{ $0.str }.joined(separator: "\n")
        try? data.write(to: fileName, atomically: false, encoding: String.Encoding.utf8)
        dispatchGroup.wait() // Wait until last image saved
        
        captureButton.setTitle("Capture", for: .normal)
    }
    
    func recordData() { // Every frame's process in record mode
        guard let data = getFrameData() else {return}
        captureData.append(data)
        
        let snap = session.currentFrame!.capturedImage
        let num = currentCaptureFrame // Image sequence's filename
        
        dispatchGroup.enter()
        saveQueue.async{
            autoreleasepool { // Prevent JPEG conversion memory leak
                let writePath = self.folderPath.appendingPathComponent( String(format: "%04d", num)+".jpg" )
                try? UIImageJPEGRepresentation(UIImage(pixelBuffer: snap), 0.85)?.write(to: writePath)
                self.dispatchGroup.leave()
            }
        }

        currentCaptureFrame += 1
    }
    
    func getFrameData() -> CaptureData? { // Organize arkit's data
        let arFrame = session.currentFrame!
        guard let anchor = arFrame.anchors[0] as? ARFaceAnchor else {return nil}
        let vertices = anchor.geometry.vertices

        let size = arFrame.camera.imageResolution
        let camera = arFrame.camera

        let modelMatrix = anchor.transform
        let textureCoordinates = vertices.map { vertex -> vector_float2 in
            let vertex4 = vector_float4(vertex.x, vertex.y, vertex.z, 1)
            let world_vertex4 = simd_mul(modelMatrix, vertex4)
            let world_vector3 = simd_float3(x: world_vertex4.x, y: world_vertex4.y, z: world_vertex4.z)
            let pt = camera.projectPoint(world_vector3,
                orientation: .portrait,
                viewportSize: CGSize(
                    width: CGFloat(size.height),
                    height: CGFloat(size.width)))
            let v = Float(pt.x) / Float(size.height)
            let u = Float(pt.y) / Float(size.width)
            return vector_float2(u, v)
        }
        let data = CaptureData(vertices: vertices, camTransform: arFrame.camera.transform, faceTransform: anchor.transform, blendShapes: anchor.blendShapes, uvs: textureCoordinates)
        return data
    }
    
    // utility
    func folderName() -> String {
        let dateFormatter : DateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMdd_HHmmss"
        let date = Date()
        let folderStr = dateFormatter.string(from: date)
        return folderStr
    }
    
    func popRecordSetting() {
        let alert = UIAlertController(title: "Record Setting", message: "Set frames per second.", preferredStyle: .alert)
        
        alert.addTextField(configurationHandler: { textField in
            textField.placeholder = "\(self.fps)"
            textField.keyboardType = .decimalPad
        })
        
        let okAction = UIAlertAction(title: "Accept", style: .default, handler: { (action) -> Void in
            self.fps = Double(alert.textFields![0].text!)!
            self.refreshInfo()
        })
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: {(action) -> Void in})
        
        alert.addAction(okAction)
        alert.addAction(cancelAction)
        
        self.present(alert, animated: true, completion: nil)
    }
}
