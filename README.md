## Whisper Streaming with Ray Serve on Amazon EKS

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

Whisper Streaming is a Ray Serve-based ASR solution that enables realtime audio streaming and transcription using WebSocket. The system employs Huggingface's Voice Activity Detection (VAD) and OpenAI's Whisper model (faster-whisper being the default) for accurate speech recognition and processing. The soruce is based on VoiceStreamAI https://github.com/lindarr915/VoiceStreamAI.

The real-time streaing ASR can be used in the following use cases: 

* closed caption
* dictation, email, messaging
* dialogs systems
* front-end for online conference translation
* court protocols
* any sort of online transcription of microphone data

The project is composed of containing multiple ML models (VAD and Whisper model) and buffering logic. Hence, I will introduce the concpet of Ray's [Deploy Compositions of Models](https://docs.ray.io/en/latest/serve/model_composition.html#compose-deployments-using-deploymenthandles) to independently scale and configure each of the ML models and business logic (buffering)

## Deployment 

1. Start [Amazon EKS Cluster with GPUs](https://docs.ray.io/en/latest/cluster/kubernetes/user-guides/aws-eks-gpu-cluster.html)

2. Install Karpenter, NodePool and EC2NodeClass for compute provisioning for Kubernetes clusters.
```
kubecly apply -f ./karpenter
```
3. Install the Helm Chart of [KubeRay](https://github.com/ray-project/kuberay)

```
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm repo update

# Install both CRDs and KubeRay operator v1.0.0.
helm install kuberay-operator kuberay/kuberay-operator --version 1.0.0

# Check the KubeRay operator Pod in `default` namespace
kubectl get pods
# NAME                                READY   STATUS    RESTARTS   AGE
# kuberay-operator-6fcbb94f64-mbfnr   1/1     Running   0          17s
```
4. Deploy the KubeRay Service
```
kubectl apply -f Whisper-RayService.yaml
```

Check when the 
```
❯ kubectl get pod
NAME                                                      READY   STATUS    RESTARTS       AGE
isper-streaming-raycluster-c2gdq-worker-gpu-group-6vxz5   1/1     Running   0              84m
whisper-streaming-raycluster-c2gdq-head-nxt2g             2/2     Running   0              98m
❯ kubectl get svc
NAME                                          TYPE           CLUSTER-IP       EXTERNAL-IP                                                                         PORT(S)                                                   AGE
kubernetes                                    ClusterIP      172.20.0.1       <none>                                                                              443/TCP                                                   92d
whisper-streaming-head-svc                    ClusterIP      172.20.146.174   <none>                                                                              10001/TCP,8265/TCP,52365/TCP,6379/TCP,8080/TCP,8000/TCP   5d5h
whisper-streaming-raycluster-c2gdq-head-svc   ClusterIP      172.20.89.123    <none>                                                                              10001/TCP,8265/TCP,52365/TCP,6379/TCP,8080/TCP,8000/TCP   98m
whisper-streaming-serve-svc                   ClusterIP      172.20.191.110   <none>                                                                              8000/TCP                                                  5d5h

❯ kubectl describe RayService whisper-streaming
ame:         whisper-streaming
Namespace:    default
Labels:       <none>
Annotations:  <none>
API Version:  ray.io/v1
Kind:         RayService
Metadata:
  Creation Timestamp:  2024-03-01T03:28:51Z
  Generation:          6
  Resource Version:    56238399
  UID:                 c9361d97-66ec-4f64-b7ae-434c6610a60c
Spec:
  ...
Status:
  Active Service Status:

...
  Service Status:  Running

```
## Test the Application

https://github.com/lindarr915/VoiceStreamAI/tree/main

## Demo Video

## Demo Web Interface

## Load Testing

Simluate 20 audio streams with Locust using the command:  
```
locust -u 20 --headless  -f locustfile.py    
```
## Observability

Grafana 

3 Ray Actors
- FasterWhisperASR (GPU)
- PyannoteVAD
- TranscriptionServer

Scale

Monitor the Latency 

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

