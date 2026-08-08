package com.dunwugudao.replay.mapper.ck;

import com.dunwugudao.replay.entity.ck.raw.LimitDownPool;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.time.LocalDate;
import java.util.List;

@Mapper
public interface LimitDownPoolMapper {

    List<LimitDownPool> selectByTradeDate(@Param("tradeDate") LocalDate tradeDate);
}
