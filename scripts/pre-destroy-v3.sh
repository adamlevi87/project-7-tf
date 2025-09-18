#!/bin/bash
set -euo pipefail

echo "🔥 COMPLETE KUBERNETES CLEANUP FOR TERRAFORM DESTROY"
echo "=================================================="

# 1. DELETE ALL ARGOCD APPLICATIONS FIRST
echo "🎯 Step 1: Deleting all ArgoCD Applications..."

# Find and suspend App-of-Apps
APP_OF_APPS=$(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E "(app-of-apps|apps)" | head -1 || true)
if [ -n "$APP_OF_APPS" ]; then
  echo "🔄 Suspending App-of-Apps: $APP_OF_APPS"
  kubectl patch application "$APP_OF_APPS" -n argocd --type='merge' -p='{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null || true
  sleep 5
fi

# Delete all ArgoCD applications
ALL_APPS=$(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [ -n "$ALL_APPS" ]; then
  for APP in $ALL_APPS; do
    echo "🗑 Deleting ArgoCD application: $APP"
    kubectl delete application "$APP" -n argocd --timeout=30s 2>/dev/null || {
      echo "⚠️  Force removing finalizers for: $APP"
      kubectl patch application "$APP" -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
      kubectl delete application "$APP" -n argocd --force --grace-period=0 2>/dev/null || true
    }
  done
else
  echo "ℹ️  No ArgoCD applications found"
fi

# 2. DELETE ALL TARGET GROUP BINDINGS
echo ""
echo "🎯 Step 2: Cleaning up TargetGroupBindings and ALB rules..."

ALL_NAMESPACES="argocd frontend kube-system"
for NS in $ALL_NAMESPACES; do
  echo "🌐 Processing namespace: $NS"
  
  TGBS=$(kubectl get targetgroupbindings.elbv2.k8s.aws -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if [ -n "$TGBS" ]; then
    for TGB_NAME in $TGBS; do
      echo "🔍 Processing TGB: $TGB_NAME"
      
      # Get TGB ARN
      TGB_ARN=$(kubectl get targetgroupbinding "$TGB_NAME" -n "$NS" -o jsonpath='{.spec.targetGroupARN}' 2>/dev/null || true)
      
      if [ -n "$TGB_ARN" ]; then
        echo "➡️  TargetGroup ARN: $TGB_ARN"
        
        # Get Load Balancer ARN
        LB_ARN=$(aws elbv2 describe-target-groups --target-group-arns "$TGB_ARN" --query 'TargetGroups[0].LoadBalancerArns[0]' --output text 2>/dev/null || true)
        
        if [ -n "$LB_ARN" ] && [ "$LB_ARN" != "None" ]; then
          echo "➡️  Load Balancer ARN: $LB_ARN"
          
          # Delete ALB rules pointing to this TGB
          LISTENER_ARNS=$(aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" --query 'Listeners[*].ListenerArn' --output text 2>/dev/null || true)
          
          for LISTENER_ARN in $LISTENER_ARNS; do
            if [ -n "$LISTENER_ARN" ]; then
              RULES=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --output json 2>/dev/null || echo '{"Rules":[]}')
              MATCHED_RULE_ARN=$(echo "$RULES" | jq -r --arg TGB_ARN "$TGB_ARN" '.Rules[] | select(.Actions[].TargetGroupArn == $TGB_ARN) | .RuleArn' 2>/dev/null || true)
              
              if [[ -n "$MATCHED_RULE_ARN" && "$MATCHED_RULE_ARN" != "null" ]]; then
                echo "🗑 Deleting ALB rule: $MATCHED_RULE_ARN"
                aws elbv2 delete-rule --rule-arn "$MATCHED_RULE_ARN" 2>/dev/null || true
              fi
            fi
          done
        fi
      fi
      
      # Delete the TGB
      echo "🗑 Deleting TargetGroupBinding: $TGB_NAME"
      kubectl delete targetgroupbinding "$TGB_NAME" -n "$NS" 2>/dev/null || true
    done
  else
    echo "ℹ️  No TargetGroupBindings in namespace: $NS"
  fi
done

# 3. DELETE ALL INGRESSES
echo ""
echo "🎯 Step 3: Deleting all Ingresses..."

for NS in $ALL_NAMESPACES; do
  INGRESSES=$(kubectl get ingress -n "$NS" -o name 2>/dev/null || true)
  if [ -n "$INGRESSES" ]; then
    for INGRESS in $INGRESSES; do
      echo "🗑 Deleting ingress: $NS/$INGRESS"
      kubectl delete "$INGRESS" -n "$NS" --timeout=30s 2>/dev/null || true
    done
  fi
done

# # 4. DELETE SERVICES WITH LOAD BALANCERS
# echo ""
# echo "🎯 Step 4: Deleting LoadBalancer services..."

# for NS in $ALL_NAMESPACES; do
#   LB_SERVICES=$(kubectl get services -n "$NS" -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
#   if [ -n "$LB_SERVICES" ]; then
#     for SVC in $LB_SERVICES; do
#       echo "🗑 Deleting LoadBalancer service: $NS/$SVC"
#       kubectl delete service "$SVC" -n "$NS" --timeout=60s 2>/dev/null || true
#     done
#   fi
# done

# 5. DELETE PERSISTENT VOLUME CLAIMS
echo ""
echo "🎯 Step 5: Deleting PersistentVolumeClaims..."

for NS in $ALL_NAMESPACES; do
  PVCS=$(kubectl get pvc -n "$NS" -o name 2>/dev/null || true)
  if [ -n "$PVCS" ]; then
    for PVC in $PVCS; do
      echo "🗑 Deleting PVC: $NS/$PVC"
      kubectl delete "$PVC" -n "$NS" --timeout=30s 2>/dev/null || true
    done
  fi
done

# 6. REMOVE FINALIZERS FROM STUCK RESOURCES
echo ""
echo "🎯 Step 6: Removing finalizers from stuck resources..."

# Remove finalizers from ingresses
kubectl get ingress -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers[]? | startswith("group.ingress.k8s.aws/") or startswith("elbv2.k8s.aws/")) | "\(.metadata.namespace) \(.metadata.name)"' | while read ns name; do
  if [ -n "$ns" ] && [ -n "$name" ]; then
    echo "🛠 Removing finalizers from ingress: $ns/$name"
    kubectl patch ingress "$name" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
  fi
done

# Remove finalizers from services
kubectl get services -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers[]? | startswith("service.k8s.aws/")) | "\(.metadata.namespace) \(.metadata.name)"' | while read ns name; do
  if [ -n "$ns" ] && [ -n "$name" ]; then
    echo "🛠 Removing finalizers from service: $ns/$name"
    kubectl patch service "$name" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
  fi
done

# 7. WAIT FOR CLEANUP
echo ""
echo "🎯 Step 7: Waiting for cleanup to complete..."
sleep 30

# 8. FORCE DELETE STUCK NAMESPACES
echo ""
echo "🎯 Step 8: Final cleanup check..."

for NS in frontend argocd; do
  if kubectl get namespace "$NS" >/dev/null 2>&1; then
    echo "ℹ️  Namespace $NS still exists (normal - Terraform will handle it)"
  fi
done

echo ""
echo "🎉 CLEANUP COMPLETE!"
echo "=================================================="
echo "✅ All ArgoCD applications deleted"
echo "✅ All TargetGroupBindings and ALB rules deleted" 
echo "✅ All Ingresses deleted"
echo "✅ All LoadBalancer services deleted"
echo "✅ All PVCs deleted"
echo "✅ Finalizers removed from stuck resources"
echo ""
echo "🚀 You can now safely run: terraform destroy"
echo "=================================================="