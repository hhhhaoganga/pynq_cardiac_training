// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2024.2 (64-bit)
// Tool Version Limit: 2024.11
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2024 Advanced Micro Devices, Inc. All Rights Reserved.
// 
// ==============================================================
/***************************** Include Files *********************************/
#include "xshape_top.h"

/************************** Function Implementation *************************/
#ifndef __linux__
int XShape_top_CfgInitialize(XShape_top *InstancePtr, XShape_top_Config *ConfigPtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(ConfigPtr != NULL);

    InstancePtr->Control_BaseAddress = ConfigPtr->Control_BaseAddress;
    InstancePtr->IsReady = XIL_COMPONENT_IS_READY;

    return XST_SUCCESS;
}
#endif

void XShape_top_Start(XShape_top *InstancePtr) {
    u32 Data;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XShape_top_ReadReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_AP_CTRL) & 0x80;
    XShape_top_WriteReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_AP_CTRL, Data | 0x01);
}

u32 XShape_top_IsDone(XShape_top *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XShape_top_ReadReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_AP_CTRL);
    return (Data >> 1) & 0x1;
}

u32 XShape_top_IsIdle(XShape_top *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XShape_top_ReadReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_AP_CTRL);
    return (Data >> 2) & 0x1;
}

u32 XShape_top_IsReady(XShape_top *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XShape_top_ReadReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_AP_CTRL);
    // check ap_start to see if the pcore is ready for next input
    return !(Data & 0x1);
}

void XShape_top_EnableAutoRestart(XShape_top *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XShape_top_WriteReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_AP_CTRL, 0x80);
}

void XShape_top_DisableAutoRestart(XShape_top *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XShape_top_WriteReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_AP_CTRL, 0);
}

void XShape_top_InterruptGlobalEnable(XShape_top *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XShape_top_WriteReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_GIE, 1);
}

void XShape_top_InterruptGlobalDisable(XShape_top *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XShape_top_WriteReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_GIE, 0);
}

void XShape_top_InterruptEnable(XShape_top *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XShape_top_ReadReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_IER);
    XShape_top_WriteReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_IER, Register | Mask);
}

void XShape_top_InterruptDisable(XShape_top *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XShape_top_ReadReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_IER);
    XShape_top_WriteReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_IER, Register & (~Mask));
}

void XShape_top_InterruptClear(XShape_top *InstancePtr, u32 Mask) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XShape_top_WriteReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_ISR, Mask);
}

u32 XShape_top_InterruptGetEnabled(XShape_top *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XShape_top_ReadReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_IER);
}

u32 XShape_top_InterruptGetStatus(XShape_top *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XShape_top_ReadReg(InstancePtr->Control_BaseAddress, XSHAPE_TOP_CONTROL_ADDR_ISR);
}

