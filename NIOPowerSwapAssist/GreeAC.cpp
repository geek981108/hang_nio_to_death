#include "GreeAC.h"
#include "driver/rmt_tx.h"
#include "driver/rmt_encoder.h"
#include "esp_log.h"

void GreeAC::_sendMark(uint32_t usec)
{
    if (usec == 0)
        return;

    // 使用新驱动发送mark信号
    rmt_transmit_config_t tx_cfg = {
        .loop_count = 0,  // 不循环
        .flags = {
            .eot_level = 0,  // 结束时电平为低
        }
    };

    // 创建发送项
    rmt_encoder_t *encoder = rmt_new_ir_nec_encoder();
    if (!encoder) {
        ESP_LOGE("GreeAC", "Failed to create IR NEC encoder");
        return;
    }

    // 发送数据
    rmt_transmit(_channel, encoder, &tx_cfg, usec, 1, true);
    
    // 等待发送完成
    rmt_tx_wait_all_done(_channel, portMAX_DELAY);

    // 清理编码器
    rmt_del_encoder(encoder);
} 